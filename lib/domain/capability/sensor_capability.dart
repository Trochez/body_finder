enum SensorType {
  bluetoothLowEnergy,
  wifi,
  wifiRtt,
  wifiCsi,
  uwbRanging,
  rawUwb,
  accelerometer,
  gyroscope,
  magnetometer,
  barometer,
  gnss,
  microphone,
}

enum PermissionState { granted, denied, restricted, notRequired, unknown }

enum CapabilityClass {
  commonAndExposed,
  selectedDevices,
  hardwareApiRestricted,
  researchOnly,
  unavailable,
}

class SensorCapability {
  const SensorCapability({
    required this.type,
    required this.hardwareAvailable,
    required this.apiAvailable,
    required this.permissionState,
    required this.measurementAvailable,
    required this.capabilityClass,
    required this.estimatedQuality,
    this.restrictionReason,
  });

  final SensorType type;
  final bool hardwareAvailable;
  final bool apiAvailable;
  final PermissionState permissionState;
  final bool measurementAvailable;
  final CapabilityClass capabilityClass;
  final double estimatedQuality;
  final String? restrictionReason;

  factory SensorCapability.fromMap(Map<Object?, Object?> map) {
    final quality = ((map['estimatedQuality'] as num?) ?? 0).toDouble();
    return SensorCapability(
      type: _enumByName(SensorType.values, map['sensorType'] as String?),
      hardwareAvailable: map['hardwareAvailable'] == true,
      apiAvailable: map['apiAvailable'] == true,
      permissionState: _enumByName(
        PermissionState.values,
        map['permissionState'] as String?,
        fallback: PermissionState.unknown,
      ),
      measurementAvailable: map['measurementAvailable'] == true,
      capabilityClass: _enumByName(
        CapabilityClass.values,
        map['capabilityClass'] as String?,
        fallback: CapabilityClass.unavailable,
      ),
      estimatedQuality: quality.clamp(0, 1),
      restrictionReason: map['restrictionReason'] as String?,
    );
  }
}

class NodeCapabilities {
  const NodeCapabilities({
    required this.platform,
    required this.platformVersion,
    required this.capabilities,
  });

  final String platform;
  final String platformVersion;
  final List<SensorCapability> capabilities;

  factory NodeCapabilities.fromMap(Map<Object?, Object?> map) {
    final raw = (map['capabilities'] as List<Object?>?) ?? const [];
    return NodeCapabilities(
      platform: (map['platform'] as String?) ?? 'unknown',
      platformVersion: (map['platformVersion'] as String?) ?? 'unknown',
      capabilities: raw
          .whereType<Map<Object?, Object?>>()
          .map(SensorCapability.fromMap)
          .toList(growable: false),
    );
  }
}

T _enumByName<T extends Enum>(
  List<T> values,
  String? name, {
  T? fallback,
}) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  if (fallback != null) return fallback;
  throw FormatException('Unknown enum value: $name');
}
