import 'dart:async';
import 'dart:convert';
import 'dart:io';
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
/// Payloads are opportunistically zlib-compressed before 20-byte BLE framing.
/// This is especially useful for repetitive JSON range/RF telemetry and reduces
/// the number of GATT operations required to deliver one logical update. Small
/// payloads remain raw when compression would not make them smaller. Receivers
/// continue to accept legacy raw payloads.
class BleSessionTransport implements SessionTransport {
  BleSessionTransport({
    required this.nodeId,
    required BleSessionPlatformAdapter platformAdapter,
    BleSessionFramer? framer,
    BleSessionReassembler? reassembler,
  })  : _platformAdapter = platformAdapter,
        _framer = framer ?? BleSessionFramer(),
        _reassembler = reassembler ?? BleSessionReassembler();

  static const List<int> _compressedEnvelope = <int>[0x42, 0x46, 0x5a, 0x01];

  final String nodeId;
  final BleSessionPlatformAdapter _platformAdapter;
  final BleSessionFramer _framer;
  final BleSessionReassembler _reassembler;

  SessionTransportMessageHandler? _onMessage;
  SessionTransportStatusHandler? _onStatus;
  String _status = 'idle';

  @override
  String get id => 'bleControl';

  @override
  bool get isRunning => _platformAdapter.isRunning;

  String get status => _status;

  @override
  Future<void> start({
    required SessionTransportMessageHandler onMessage,
    SessionTransportStatusHandler? onStatus,
  }) async {
    if (isRunning) return;
    if (!RegExp(r'^[0-9a-fA-F]{16}$').hasMatch(nodeId)) {
      throw StateError('BLE session transport requires a 16-hex node id.');
    }

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
    final wirePayload = _encodeWirePayload(payload);
    for (final chunk in _framer.fragment(wirePayload)) {
      await _platformAdapter.sendChunk(chunk);
    }
  }

  @override
  Future<void> stop() async {
    await _platformAdapter.stop();
    _reassembler.clear();
    _onMessage = null;
    _onStatus = null;
    _status = 'idle';
  }

  void _handleChunk(BleSessionChunk incoming) {
    final wirePayload = _reassembler.accept(
      sourceKey: incoming.sourceKey,
      chunk: incoming.bytes,
    );
    if (wirePayload == null) return;

    final complete = _decodeWirePayload(wirePayload);
    if (complete == null) return;

    if (_platformAdapter is BleSessionPeerIdentityBinder) {
      final binder = _platformAdapter as BleSessionPeerIdentityBinder;
      final peerNodeId = _peerNodeIdFromPayload(complete);
      if (peerNodeId != null) {
        binder.bindPeerIdentity(
          sourceKey: incoming.sourceKey,
          nodeId: peerNodeId,
        );
      }
    }
    _onMessage?.call(complete);
  }

  static Uint8List _encodeWirePayload(Uint8List payload) {
    if (payload.isEmpty) return payload;
    final compressed = zlib.encode(payload);
    if (compressed.length + _compressedEnvelope.length >= payload.length) {
      return payload;
    }
    return Uint8List.fromList(<int>[..._compressedEnvelope, ...compressed]);
  }

  static Uint8List? _decodeWirePayload(Uint8List payload) {
    if (!_hasCompressedEnvelope(payload)) return payload;
    try {
      return Uint8List.fromList(
        zlib.decode(payload.sublist(_compressedEnvelope.length)),
      );
    } on FormatException {
      return null;
    } catch (_) {
      return null;
    }
  }

  static bool _hasCompressedEnvelope(Uint8List payload) {
    if (payload.length <= _compressedEnvelope.length) return false;
    for (var index = 0; index < _compressedEnvelope.length; index++) {
      if (payload[index] != _compressedEnvelope[index]) return false;
    }
    return true;
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
}
