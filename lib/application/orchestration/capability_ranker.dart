import '../../domain/capability/sensor_capability.dart';

class RankedCapability {
  const RankedCapability(this.capability, this.score);
  final SensorCapability capability;
  final double score;
}

List<RankedCapability> rankCapabilities(Iterable<SensorCapability> capabilities) {
  final ranked = capabilities.map((capability) {
    final availability = capability.hardwareAvailable && capability.apiAvailable ? 1.0 : 0.0;
    final readiness = capability.measurementAvailable ? 1.0 : 0.35;
    final score = capability.estimatedQuality * availability * readiness;
    return RankedCapability(capability, score.clamp(0.0, 1.0));
  }).toList();
  ranked.sort((a, b) => b.score.compareTo(a.score));
  return ranked;
}
