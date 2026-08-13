import '../../domain/geometry/vec2.dart';

class Polygon2D {
  const Polygon2D(this.vertices);
  final List<Vec2> vertices;
}

Polygon2D convexBoundary(Iterable<Vec2> input) {
  final points = input.toList()
    ..sort((a, b) => a.x == b.x ? a.y.compareTo(b.y) : a.x.compareTo(b.x));
  if (points.length <= 2) return Polygon2D(points);

  double cross(Vec2 o, Vec2 a, Vec2 b) =>
      (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);

  final lower = <Vec2>[];
  for (final point in points) {
    while (lower.length >= 2 && cross(lower[lower.length - 2], lower.last, point) <= 0) {
      lower.removeLast();
    }
    lower.add(point);
  }

  final upper = <Vec2>[];
  for (final point in points.reversed) {
    while (upper.length >= 2 && cross(upper[upper.length - 2], upper.last, point) <= 0) {
      upper.removeLast();
    }
    upper.add(point);
  }

  lower.removeLast();
  upper.removeLast();
  return Polygon2D([...lower, ...upper]);
}
