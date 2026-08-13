import '../../domain/geometry/vec2.dart';

class DemoScenario {
  const DemoScenario({required this.phonePositions, required this.syntheticMarkers});

  final List<Vec2> phonePositions;
  final List<Vec2> syntheticMarkers;

  static const room = DemoScenario(
    phonePositions: [
      Vec2(0, 0),
      Vec2(8, 0),
      Vec2(8, 6),
      Vec2(0, 6),
    ],
    syntheticMarkers: [Vec2(3.2, 2.4), Vec2(6.1, 4.5)],
  );
}
