import 'dart:async';
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

/// Body Finder session/control traffic over BLE.
///
/// This is a communication transport only. BLE RSSI ranging is implemented by
/// a separate adapter and is the physical measurement source; merely carrying
/// session bytes over BLE never creates a range or anomaly observation.
class BleSessionTransport implements SessionTransport {
  BleSessionTransport({
    required this.nodeId,
    required BleSessionPlatformAdapter platformAdapter,
    BleSessionFramer? framer,
    BleSessionReassembler? reassembler,
  })  : _platformAdapter = platformAdapter,
        _framer = framer ?? BleSessionFramer(),
        _reassembler = reassembler ?? BleSessionReassembler();

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
    for (final chunk in _framer.fragment(payload)) {
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
    final complete = _reassembler.accept(
      sourceKey: incoming.sourceKey,
      chunk: incoming.bytes,
    );
    if (complete != null) {
      _onMessage?.call(complete);
    }
  }

  void _setStatus(String value) {
    if (value.isEmpty || _status == value) return;
    _status = value;
    _onStatus?.call(value);
  }
}
