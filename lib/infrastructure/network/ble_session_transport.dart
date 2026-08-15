import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'ble_session_framer.dart';
import 'session_transport.dart';

class BleSessionChunk {
  const BleSessionChunk({
    required this.sourceKey,
    required this.bytes,
  });

  final String sourceKey;
  final Uint8List bytes;
}

typedef BleSessionChunkHandler = void Function(BleSessionChunk chunk);
typedef BleSessionPlatformStatusHandler = void Function(String status);

abstract interface class BleSessionPlatformAdapter {
  bool get isRunning;

  Future<String> start({
    required String nodeId,
    required BleSessionChunkHandler onChunk,
    BleSessionPlatformStatusHandler? onStatus,
  });

  Future<void> sendChunk(Uint8List chunk);

  Future<void> stop();
}

/// Optional hook for platform adapters that need to bind a transport-level
/// source key (for example a BLE MAC address) to Body Finder's persistent node
/// identity after a complete session payload has been received.
///
/// The session payload is authoritative for logical membership. Advertisement
/// bytes remain discovery hints only and are not required to be parsed before a
/// GATT connection can be established.
abstract interface class BleSessionPeerIdentityBinder {
  void bindPeerIdentity({required String sourceKey, required String nodeId});
}

/// Body Finder session/control traffic over BLE.
///
/// This is a communication transport only. BLE RSSI ranging is implemented by
/// a separate adapter and is the physical measurement source; merely carrying
/// session bytes over BLE never creates a range or anomaly observation.
///
/// Valid Body Finder session payloads are also gossiped across already-linked
/// BLE peers. This lets A <-> B <-> C converge as one logical session without
/// requiring A and C to discover/connect to each other directly. Forwarded
/// membership is transport metadata only; it never fabricates a physical range.
class BleSessionTransport implements SessionTransport {
  BleSessionTransport({
    required this.nodeId,
    required BleSessionPlatformAdapter platformAdapter,
    BleSessionFramer? framer,
    BleSessionReassembler? reassembler,
    this.gossipTtl = const Duration(seconds: 8),
  })  : _platformAdapter = platformAdapter,
        _framer = framer ?? BleSessionFramer(),
        _reassembler = reassembler ?? BleSessionReassembler();

  final String nodeId;
  final BleSessionPlatformAdapter _platformAdapter;
  final BleSessionFramer _framer;
  final BleSessionReassembler _reassembler;
  final Duration gossipTtl;
  final Map<String, DateTime> _recentSessionPayloads = <String, DateTime>{};

  SessionTransportMessageHandler? _onMessage;
  SessionTransportStatusHandler? _onStatus;
  String _status = 'idle';
  int _gossipRelayCount = 0;
  int _gossipDuplicateCount = 0;

  @override
  String get id => 'bleControl';

  @override
  bool get isRunning => _platformAdapter.isRunning;

  String get status => _status;
  int get gossipRelayCount => _gossipRelayCount;
  int get gossipDuplicateCount => _gossipDuplicateCount;

  @override
  Future<void> start({
    required SessionTransportMessageHandler onMessage,
    SessionTransportStatusHandler? onStatus,
  }) async {
    if (isRunning) return;
    if (!RegExp(r'^[0-9a-fA-F]{16}$').hasMatch(nodeId)) {
      throw StateError('BLE session transport requires a 16-hex node id.');
    }

    _recentSessionPayloads.clear();
    _gossipRelayCount = 0;
    _gossipDuplicateCount = 0;
    _onMessage = onMessage;
    _onStatus = onStatus;
    final status = await _platformAdapter.start(
      nodeId: nodeId,
      onStatus: _setStatus,
      onChunk: _handleChunk,
    );
    _setStatus(status);
    if (!isRunning) {
      _onMessage = null;
      throw StateError('BLE session transport did not start: $status');
    }
  }

  @override
  Future<void> broadcast(Uint8List payload) async {
    if (!isRunning || payload.isEmpty) return;
    if (_peerNodeIdFromPayload(payload) != null) {
      _rememberSessionPayload(payload);
    }
    await _sendPayload(payload);
  }

  @override
  Future<void> stop() async {
    await _platformAdapter.stop();
    _reassembler.clear();
    _recentSessionPayloads.clear();
    _onMessage = null;
    _onStatus = null;
    _status = 'idle';
    _gossipRelayCount = 0;
    _gossipDuplicateCount = 0;
  }

  void _handleChunk(BleSessionChunk incoming) {
    final complete = _reassembler.accept(
      sourceKey: incoming.sourceKey,
      chunk: incoming.bytes,
    );
    if (complete == null) return;

    final peerNodeId = _peerNodeIdFromPayload(complete);
    if (peerNodeId != null) {
      _expireRecentSessionPayloads();
      final fingerprint = _fingerprint(complete);
      if (_recentSessionPayloads.containsKey(fingerprint)) {
        _gossipDuplicateCount++;
        return;
      }
      _recentSessionPayloads[fingerprint] = DateTime.now();
    }

    if (_platformAdapter is BleSessionPeerIdentityBinder && peerNodeId != null) {
      final binder = _platformAdapter as BleSessionPeerIdentityBinder;
      binder.bindPeerIdentity(
        sourceKey: incoming.sourceKey,
        nodeId: peerNodeId,
      );
    }

    _onMessage?.call(complete);

    // Gossip only valid remote Body Finder session payloads. The platform
    // adapter broadcasts chunks to its currently connected BLE peers. Echoes
    // and loops are suppressed by the short-lived payload fingerprint cache.
    if (peerNodeId != null && peerNodeId != nodeId) {
      _gossipRelayCount++;
      unawaited(_sendPayload(complete));
    }
  }

  Future<void> _sendPayload(Uint8List payload) async {
    for (final chunk in _framer.fragment(payload)) {
      await _platformAdapter.sendChunk(chunk);
    }
  }

  void _rememberSessionPayload(Uint8List payload) {
    _expireRecentSessionPayloads();
    _recentSessionPayloads[_fingerprint(payload)] = DateTime.now();
  }

  void _expireRecentSessionPayloads() {
    final cutoff = DateTime.now().subtract(gossipTtl);
    _recentSessionPayloads.removeWhere((_, seenAt) => seenAt.isBefore(cutoff));
  }

  void _setStatus(String value) {
    if (value.isEmpty || _status == value) return;
    _status = value;
    _onStatus?.call(value);
  }

  static String? _peerNodeIdFromPayload(Uint8List payload) {
    try {
      final decoded = jsonDecode(utf8.decode(payload));
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded['protocol'] != 'body_finder_peer_v1') return null;
      final value = decoded['nodeId'];
      if (value is! String) return null;
      final normalized = value.toLowerCase();
      return RegExp(r'^[0-9a-f]{16}$').hasMatch(normalized)
          ? normalized
          : null;
    } on FormatException {
      return null;
    }
  }

  /// Small deterministic FNV-1a fingerprint used only for short-lived BLE
  /// gossip loop suppression. It is not a security or identity primitive.
  static String _fingerprint(Uint8List bytes) {
    const offset = 0xcbf29ce484222325;
    const prime = 0x100000001b3;
    const mask = 0xffffffffffffffff;
    var hash = offset;
    for (final byte in bytes) {
      hash ^= byte;
      hash = (hash * prime) & mask;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }
}
