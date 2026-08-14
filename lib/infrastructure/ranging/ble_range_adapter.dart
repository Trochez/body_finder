import 'package:flutter/services.dart';

import '../../domain/geometry/range_observation.dart';

class BleRangeUpdate {
  const BleRangeUpdate({
    required this.peerNodeId,
    required this.distanceMeters,
    required this.sigmaMeters,
    required this.rssiDbm,
  });

  final String peerNodeId;
  final double distanceMeters;
  final double sigmaMeters;
  final double rssiDbm;
}

class BleRangeAdapter {
  BleRangeAdapter({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('body_finder/ble_ranging');

  final MethodChannel _channel;
  void Function(BleRangeUpdate update)? _onRange;
  void Function(String status)? _onStatus;
  bool _started = false;

  bool get started => _started;

  Future<String> start({
    required String nodeId,
    required void Function(BleRangeUpdate update) onRange,
    void Function(String status)? onStatus,
  }) async {
    _onRange = onRange;
    _onStatus = onStatus;
    _channel.setMethodCallHandler(_handleNativeCall);
    try {
      final response = await _channel.invokeMapMethod<String, dynamic>(
        'start',
        {'nodeId': nodeId},
      );
      final status = response?['status']?.toString() ?? 'unknown';
      _started = status == 'started';
      _onStatus?.call(status);
      return status;
    } on MissingPluginException {
      _started = false;
      _onStatus?.call('unsupported');
      return 'unsupported';
    } on PlatformException catch (error) {
      _started = false;
      final status = error.code;
      _onStatus?.call(status);
      return status;
    }
  }

  Future<void> stop() async {
    if (_started) {
      try {
        await _channel.invokeMethod<void>('stop');
      } on MissingPluginException {
        // Non-Android platforms intentionally have no native BLE ranging bridge yet.
      } on PlatformException {
        // Stopping is best-effort during widget/application teardown.
      }
    }
    _started = false;
    _onRange = null;
    _onStatus = null;
    _channel.setMethodCallHandler(null);
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    if (call.method == 'status') {
      final args = call.arguments;
      if (args is Map) {
        _onStatus?.call(args['status']?.toString() ?? 'unknown');
      }
      return;
    }
    if (call.method != 'range') return;
    final args = call.arguments;
    if (args is! Map) return;
    final peerNodeId = args['peerNodeId'];
    final distance = args['distanceMeters'];
    final sigma = args['sigmaMeters'];
    final rssi = args['rssiDbm'];
    if (peerNodeId is! String || distance is! num || sigma is! num || rssi is! num) {
      return;
    }
    if (!distance.isFinite || distance <= 0 || !sigma.isFinite || sigma <= 0) {
      return;
    }
    _onRange?.call(
      BleRangeUpdate(
        peerNodeId: peerNodeId,
        distanceMeters: distance.toDouble(),
        sigmaMeters: sigma.toDouble(),
        rssiDbm: rssi.toDouble(),
      ),
    );
  }

  static RangeSource get source => RangeSource.bleRssi;
}
