import 'dart:io';

import 'package:flutter/services.dart';

import '../../domain/capability/sensor_capability.dart';
import 'linux_capability_probe.dart';

typedef CapabilityProbe = Future<Map<Object?, Object?>> Function();

class SensorCapabilityManager {
  SensorCapabilityManager({CapabilityProbe? probe})
      : _probe = probe ?? _defaultProbe;

  static const _channel = MethodChannel('body_finder/capabilities');
  final CapabilityProbe _probe;

  Future<NodeCapabilities> scan() async {
    try {
      final raw = await _probe();
      return NodeCapabilities.fromMap(raw);
    } on MissingPluginException {
      return const NodeCapabilities(
        platform: 'unsupported',
        platformVersion: 'unknown',
        capabilities: [],
      );
    } on PlatformException catch (error) {
      throw CapabilityScanException(error.message ?? error.code);
    }
  }

  static Future<Map<Object?, Object?>> _defaultProbe() {
    if (Platform.isLinux) {
      return const LinuxCapabilityProbe().scan();
    }
    return _platformProbe();
  }

  static Future<Map<Object?, Object?>> _platformProbe() async {
    final raw = await _channel.invokeMapMethod<Object?, Object?>('scanCapabilities');
    return raw ?? <Object?, Object?>{};
  }
}

class CapabilityScanException implements Exception {
  const CapabilityScanException(this.message);
  final String message;

  @override
  String toString() => 'CapabilityScanException: $message';
}
