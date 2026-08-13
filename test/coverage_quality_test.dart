import 'package:body_finder/application/geometry/coverage_quality.dart';
import 'package:body_finder/domain/geometry/vec2.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('coverage improves with perimeter geometry', () {
    final sparse = evaluateCoverage(const [Vec2(0, 0), Vec2(1, 0)]);
    final perimeter = evaluateCoverage(const [
      Vec2(0, 0),
      Vec2(8, 0),
      Vec2(8, 6),
      Vec2(0, 6),
    ]);

    expect(sparse.score, 0);
    expect(perimeter.score, greaterThan(sparse.score));
    expect(perimeter.boundary.vertices.length, 4);
  });
}
