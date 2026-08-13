import 'package:body_finder/application/geometry/placement_recommender.dart';
import 'package:body_finder/domain/geometry/vec2.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('placement recommendation remains outside current line geometry', () {
    final result = recommendPlacement(const [Vec2(0, 0), Vec2(8, 0)]);
    expect(result, isNotNull);
    expect(result!.y.abs(), greaterThan(0));
  });
}
