import 'package:body_finder/application/geometry/bootstrap_layout_solver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const solver = BootstrapLayoutSolver();

  test('any three device ids receive the same deterministic 2D bootstrap layout', () {
    final first = solver.solve(const ['linux-b', 'android-a', 'ios-c']);
    final second = solver.solve(const ['ios-c', 'linux-b', 'android-a']);

    expect(first.has2DLayout, isTrue);
    expect(first.positions.length, 3);
    for (final id in first.positions.keys) {
      expect(second.positions[id]!.x, closeTo(first.positions[id]!.x, 1e-12));
      expect(second.positions[id]!.y, closeTo(first.positions[id]!.y, 1e-12));
    }
  });

  test('one and two devices also receive immediate initial positions', () {
    final one = solver.solve(const ['pc']);
    final two = solver.solve(const ['pc', 'phone']);

    expect(one.positions.keys, contains('pc'));
    expect(two.positions.keys, containsAll(['pc', 'phone']));
  });

  test('late joining device is included without requiring a session reset', () {
    final before = solver.solve(const ['a', 'b', 'c']);
    final after = solver.solve(const ['a', 'b', 'c', 'd']);

    expect(before.positions.length, 3);
    expect(after.positions.length, 4);
    expect(after.positions.keys, containsAll(['a', 'b', 'c', 'd']));
    expect(after.has2DLayout, isTrue);
  });
}
