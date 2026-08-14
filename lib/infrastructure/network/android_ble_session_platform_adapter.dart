import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'ble_session_transport.dart';

class AndroidBleSessionPlatformAdapter implements BleSessionPlatformAdapter {
  AndroidBleSessionPlatformAdapter({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('body_finder/ble_session');

  final MethodChannel _channel;
  BleSessionChunkHandler? _onChunk;
  BleSessionPlatformStatusHandler? _onStatus;
  bool _running = false;

  @override
  bool get isRunning => _running;

  @override
  Future<String> start({
    required String nodeId,
    required BleSessionChunkHandler onChunk,
    BleSessionPlatformStatusHandler? onStatus,
  }) async {
    await stop();
    _onChunk = onChunk;
    _onStatus = onStatus;
    _channel.setMethodCallHandler(_handleNativeCall);
    try {
      final response = await _channel.invokeMapMethod<String, dynamic>(
        'start',
        <String, dynamic>{'nodeId': nodeId},
      );
      final status = response?['status']?.toString() ?? 'unknown';
      _running = status == 'started' || status == 'gattReady';
      _onStatus?.call(status);
      return status;
    } on MissingPluginException {
      _running = false;
      _onStatus?.call('unsupported');
      return 'unsupported';
    } on PlatformException catch (error) {
      _running = false;
      _onStatus?.call(error.code);
      return error.code;
    }
  }

  @override
  Future<void> sendChunk(Uint8List chunk) async {
    if (!_running || chunk.isEmpty) return;
    await _channel.invokeMethod<void>(
      'sendChunk',
      <String, dynamic>{'bytes': chunk.toList(growable: false)},
    );
  }

  @override
  Future<void> stop() async {
    if (_running) {
      try {
        await _channel.invokeMethod<void>('stop');
      } on MissingPluginException {
        // Unsupported platforms are expected to fall back to other transports.
      } on PlatformException {
        // Best effort during teardown/failover.
      }
    }
    _running = false;
    _onChunk = null;
    _onStatus = null;
    _channel.setMethodCallHandler(null);
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    if (call.method == 'status') {
      final args = call.arguments;
      if (args is Map) {
        final status = args['status']?.toString() ?? 'unknown';
        if (status == 'gattReady' || status == 'started') _running = true;
        if (status == 'stopped' || status == 'failed') _running = false;
        _onStatus?.call(status);
      }
      return;
    }
    if (call.method != 'chunk') return;
    final args = call.arguments;
    if (args is! Map) return;
    final sourceKey = args['sourceKey']?.toString() ?? '';
    final raw = args['bytes'];
    if (sourceKey.isEmpty || raw is! List) return;
    final values = <int>[];
    for (final value in raw) {
      if (value is! num) return;
      final byte = value.toInt();
      if (byte < 0 || byte > 255) return;
      values.add(byte);
    }
    if (values.isEmpty) return;
    _onChunk?.call(
      BleSessionChunk(
        sourceKey: sourceKey,
        bytes: Uint8List.fromList(values),
      ),
    );
  }
}
