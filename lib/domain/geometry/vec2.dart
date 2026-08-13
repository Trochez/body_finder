import 'dart:math' as math;

class Vec2 {
  const Vec2(this.x, this.y);

  final double x;
  final double y;

  Vec2 operator +(Vec2 other) => Vec2(x + other.x, y + other.y);
  Vec2 operator -(Vec2 other) => Vec2(x - other.x, y - other.y);
  Vec2 operator *(double scale) => Vec2(x * scale, y * scale);

  double get norm => math.sqrt(x * x + y * y);
  double distanceTo(Vec2 other) => (this - other).norm;

  Map<String, double> toJson() => {'x': x, 'y': y};
}
