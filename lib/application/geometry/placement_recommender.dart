import 'dart:math' as math;

import '../../domain/geometry/vec2.dart';

Vec2? recommendPlacement(Iterable<Vec2> input, {double marginMeters = 1}) {
  final points = input.toList();
  if (points.isEmpty) return const Vec2(0, 0);

  final minX = points.map((p) => p.x).reduce(math.min) - marginMeters;
  final maxX = points.map((p) => p.x).reduce(math.max) + marginMeters;
  final minY = points.map((p) => p.y).reduce(math.min) - marginMeters;
  final maxY = points.map((p) => p.y).reduce(math.max) + marginMeters;

  final candidates = <Vec2>[
    Vec2(minX, minY),
    Vec2(maxX, minY),
    Vec2(maxX, maxY),
    Vec2(minX, maxY),
    Vec2((minX + maxX) / 2, minY),
    Vec2(maxX, (minY + maxY) / 2),
    Vec2((minX + maxX) / 2, maxY),
    Vec2(minX, (minY + maxY) / 2),
  ];

  double score(Vec2 candidate) =>
      points.map(candidate.distanceTo).reduce(math.min);

  candidates.sort((a, b) => score(b).compareTo(score(a)));
  return candidates.first;
}
