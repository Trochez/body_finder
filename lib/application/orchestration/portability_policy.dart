import '../../domain/capability/sensor_capability.dart';

enum OperatingMode {
  advanced,
  enhanced,
  universal,
  limited,
  participantOnly,
}

class OperatingProfile {
  const OperatingProfile({
    required this.mode,
    required this.label,
    required this.description,
    required this.participationAllowed,
    required this.availableSensors,
  });

  final OperatingMode mode;
  final String label;
  final String description;
  final bool participationAllowed;
  final Set<SensorType> availableSensors;
}

OperatingProfile selectOperatingProfile(NodeCapabilities node) {
  final available = node.capabilities
      .where((capability) => capability.hardwareAvailable && capability.apiAvailable)
      .map((capability) => capability.type)
      .toSet();

  final hasBle = available.contains(SensorType.bluetoothLowEnergy);
  final hasWifi = available.contains(SensorType.wifi);
  final hasImu = available.contains(SensorType.accelerometer) ||
      available.contains(SensorType.gyroscope);
  final hasRtt = available.contains(SensorType.wifiRtt);
  final hasUwb = available.contains(SensorType.uwbRanging);

  if (hasUwb && hasRtt && hasBle) {
    return OperatingProfile(
      mode: OperatingMode.advanced,
      label: 'Advanced',
      description: 'Uses all exposed high-precision ranging capabilities plus common radios.',
      participationAllowed: true,
      availableSensors: available,
    );
  }

  if ((hasUwb || hasRtt) && hasBle) {
    return OperatingProfile(
      mode: OperatingMode.enhanced,
      label: 'Enhanced',
      description: 'Uses exposed ranging where available and falls back to common radios.',
      participationAllowed: true,
      availableSensors: available,
    );
  }

  if (hasBle && (hasWifi || hasImu)) {
    return OperatingProfile(
      mode: OperatingMode.universal,
      label: 'Universal',
      description: 'Compatible baseline using common smartphone capabilities.',
      participationAllowed: true,
      availableSensors: available,
    );
  }

  if (hasBle || hasWifi || hasImu) {
    return OperatingProfile(
      mode: OperatingMode.limited,
      label: 'Limited',
      description: 'The phone can participate with reduced sensing contribution.',
      participationAllowed: true,
      availableSensors: available,
    );
  }

  return OperatingProfile(
    mode: OperatingMode.participantOnly,
    label: 'Participant only',
    description: 'No common sensing capability is exposed; keep the device available for session/UI roles.',
    participationAllowed: true,
    availableSensors: available,
  );
}
