import '../../domain/geometry/vec2.dart';

class SyntheticEstimate {
  const SyntheticEstimate({
    required this.id,
    required this.position,
    required this.confidence,
    required this.uncertaintyMeters,
  });

  final String id;
  final Vec2 position;
  final double confidence;
  final double uncertaintyMeters;
}
