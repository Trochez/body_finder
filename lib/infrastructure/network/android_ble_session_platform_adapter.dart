import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'ble_session_transport.dart';

/// Android BLE session adapter with both GATT server and GATT client roles.
///
/// The existing `body_finder/ble_session` channel exposes the phone as a
/// connectable GATT server. `body_finder/ble_peer_client` scans and connects to
/// other Android Body Finder servers. Session chunks are broadcast through both
/// directions; the higher-level session/relay transport already suppresses
/// duplicate logical messages.
class AndroidBleSessionPlatformAdapter implements BleSessionPlatformAdapter {
  AndroidBleSessionPlatformAdapter({
    MethodChannel? serverChannel,
    MethodChannel? clientChannel,
  })  : _serverChannel =
            serverChannel ?? const MethodChannel('body_finder/ble_session'),
        _clientChannel = clientChannel ??
            const MethodChannel('body_finder/ble_peer_client');

  final MethodChannel _serverChannel;
  final MethodChannel _clientChannel;
  BleSessionChunkHandler? _onChunk;
  BleSessionPlatformStatusHandler? _onStatus;
  bool _serverRunning = false;
  bool _clientRunning = false;

  @override
  bool get isRunning => _serverRunning || _clientRunning;

  @override
  Future<String> start({
    required String nodeId,
    required BleSessionChunkHandler onChunk,
    BleSessionPlatformStatusHandler? onStatus,
  }) async {
    await stop();
    _onChunk = onChunk;
    _onStatus = onStatus;
    _serverChannel.setMethodCallHandler(
      (call) => _handleNativeCall(call, _TransportSide.server),
    );
    _clientChannel.setMethodCallHandler(
      (call) => _handleNativeCall(call, _TransportSide.client),
    );

    final serverStatus = await _startSide(
      channel: _serverChannel,
      nodeId: nodeId,
      side: _TransportSide.server,
    );
    final clientStatus = await _startSide(
      channel: _clientChannel,
      nodeId: nodeId,
      side: _TransportSide.client,
    );

    if (_serverRunning && _clientRunning) {
      const status = 'androidMobileBleReady';
      _onStatus?.call(status);
      return status;
    }
    if (_serverRunning) return serverStatus;
    if (_clientRunning) return clientStatus;
    return clientStatus == 'unknown' ? serverStatus : clientStatus;
  }

  Future<String> _startSide({
    required MethodChannel channel,
    required String nodeId,
    required _TransportSide side,
  }) async {
    try {
      final response = await channel.invokeMapMethod<String, dynamic>(
        'start',
        <String, dynamic>{'nodeId': nodeId},
      );
      final status = response?['status']?.toString() ?? 'unknown';
      _setSideRunning(side, _isRunningStatus(status));
      _onStatus?.call(status);
      return status;
    } on MissingPluginException {
      _setSideRunning(side, false);
      _onStatus?.call('unsupported');
      return 'unsupported';
    } on PlatformException catch (error) {
      _setSideRunning(side, false);
      _onStatus?.call(error.code);
      return error.code;
    }
  }

  @override
  Future<void> sendChunk(Uint8List chunk) async {
    if (!isRunning || chunk.isEmpty) return;
    final args = <String, dynamic>{'bytes': chunk.toList(growable: false)};
    if (_serverRunning) {
      try {
        await _serverChannel.invokeMethod<void>('sendChunk', args);
      } on MissingPluginException {
        _serverRunning = false;
      } on PlatformException {
        // Keep the client path alive if the server path temporarily fails.
      }
    }
    if (_clientRunning) {
      try {
        await _clientChannel.invokeMethod<void>('sendChunk', args);
      } on MissingPluginException {
        _clientRunning = false;
      } on PlatformException {
        // Keep the server path alive if the client path temporarily fails.
      }
    }
  }

  @override
  Future<void> stop() async {
    await _stopSide(_serverChannel, _serverRunning);
    await _stopSide(_clientChannel, _clientRunning);
    _serverRunning = false;
    _clientRunning = false;
    _onChunk = null;
    _onStatus = null;
    _serverChannel.setMethodCallHandler(null);
    _clientChannel.setMethodCallHandler(null);
  }

  Future<void> _stopSide(MethodChannel channel, bool running) async {
    if (!running) return;
    try {
      await channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // Unsupported platforms are expected to fall back to other transports.
    } on PlatformException {
      // Best effort during teardown/failover.
    }
  }

  Future<void> _handleNativeCall(
    MethodCall call,
    _TransportSide side,
  ) async {
    if (call.method == 'status') {
      final args = call.arguments;
      if (args is Map) {
        final status = args['status']?.toString() ?? 'unknown';
        if (_isRunningStatus(status)) _setSideRunning(side, true);
        if (_isTerminalFailureStatus(status)) _setSideRunning(side, false);
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

  void _setSideRunning(_TransportSide side, bool value) {
    switch (side) {
      case _TransportSide.server:
        _serverRunning = value;
        break;
      case _TransportSide.client:
        _clientRunning = value;
        break;
    }
  }

  static bool _isRunningStatus(String status) => <String>{
        'started',
        'advertisingReady',
        'gattReady',
        'readyForPeer',
        'peerConnected',
        'peerSubscribed',
        'androidPeerScanStarted',
        'androidPeerDiscovered',
        'androidPeerConnecting',
        'androidPeerConnected',
        'androidPeerSubscribing',
        'androidPeerSubscribed',
        'androidMobileBleReady',
      }.contains(status);

  static bool _isTerminalFailureStatus(String status) => <String>{
        'stopped',
        'failed',
        'advertiseFailed',
        'serviceAddFailed',
        'bluetoothOff',
        'permissionDenied',
        'unavailable',
        'androidPeerScanFailed',
        'androidPeerPermissionDenied',
      }.contains(status);
}

enum _TransportSide { server, client }
