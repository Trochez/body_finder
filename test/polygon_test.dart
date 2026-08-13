import 'package:body_finder/application/geometry/polygon.dart';
import 'package:body_finder/domain/geometry/vec2.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('convex boundary excludes interior points', () {
    final polygon = convexBoundary(const [
      Vec2(0, 0),
      Vec2(8, 0),
      Vec2(8, 6),
      Vec2(0, 6),
      Vec2(4, 3),
    ]);

    expect(polygon.vertices.length, 4);
    expect(polygon.vertices.any((p) => p.x == 4 && p.y == 3), isFalse);
  });
}
