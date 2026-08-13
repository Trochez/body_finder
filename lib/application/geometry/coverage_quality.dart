import '../../domain/geometry/vec2.dart';
import 'polygon.dart';

class CoverageQuality {
  const CoverageQuality({required this.score, required this.boundary});
  final double score;
  final Polygon2D boundary;
}

CoverageQuality evaluateCoverage(Iterable<Vec2> points) {
  final list = points.toList();
  final boundary = convexBoundary(list);
  if (list.length < 3 || boundary.vertices.length < 3) {
    return CoverageQuality(score: 0, boundary: boundary);
  }

  var twiceArea = 0.0;
  for (var i = 0; i < boundary.vertices.length; i++) {
    final a = boundary.vertices[i];
    final b = boundary.vertices[(i + 1) % boundary.vertices.length];
    twiceArea += a.x * b.y - b.x * a.y;
  }
  final area = twiceArea.abs() / 2;
  final countScore = (list.length / 8).clamp(0.0, 1.0);
  final areaScore = (area / 48).clamp(0.0, 1.0);
  return CoverageQuality(
    score: (0.55 * countScore + 0.45 * areaScore).clamp(0.0, 1.0),
    boundary: boundary,
  );
}
