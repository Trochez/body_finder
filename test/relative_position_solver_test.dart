import 'dart:math' as math;

import 'package:body_finder/application/geometry/relative_position_solver.dart';
import 'package:body_finder/domain/geometry/range_observation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const solver = RelativePositionSolver();

  RangeObservation range(String a, String b, double distance) => RangeObservation(
        fromNodeId: a,
        toNodeId: b,
        distanceMeters: distance,
        sigmaMeters: 0.05,
        timestampMicros: 100,
        source: RangeSource.uwb,
      );

  RangeObservation observation(
    String a,
    String b,
    double distance, {
    required RangeSource source,
    required int timestamp,
    required double sigma,
  }) =>
      RangeObservation(
        fromNodeId: a,
        toNodeId: b,
        distanceMeters: distance,
        sigmaMeters: sigma,
        timestampMicros: timestamp,
        source: source,
      );

  test('three pairwise ranges create a deterministic 2D frame', () {
    final result = solver.solve(
      activeNodeIds: const ['a', 'b', 'c'],
      observations: [
        range('a', 'b', 4),
        range('a', 'c', math.sqrt(10)),
        range('b', 'c', math.sqrt(18)),
      ],
    );

    expect(result.has2DFrame, isTrue);
    expect(result.unresolvedNodeIds, isEmpty);
    expect(result.positions['a']!.position.x, closeTo(0, 1e-6));
    expect(result.positions['a']!.position.y, closeTo(0, 1e-6));
    expect(result.positions['b']!.position.x, closeTo(4, 1e-6));
    expect(result.positions['c']!.position.x, closeTo(1, 1e-6));
    expect(result.positions['c']!.position.y, closeTo(3, 1e-6));
  });

  test('higher precision UWB wins over a fresher BLE observation', () {
    final result = solver.solve(
      activeNodeIds: const ['a', 'b', 'c'],
      observations: [
        observation('a', 'b', 4, source: RangeSource.uwb, timestamp: 100, sigma: 0.08),
        observation('a', 'b', 9, source: RangeSource.bleRssi, timestamp: 500, sigma: 4),
        observation('a', 'c', math.sqrt(10), source: RangeSource.uwb, timestamp: 100, sigma: 0.08),
        observation('b', 'c', math.sqrt(18), source: RangeSource.uwb, timestamp: 100, sigma: 0.08),
      ],
    );

    expect(result.has2DFrame, isTrue);
    expect(result.positions['b']!.position.x, closeTo(4, 1e-6));
    expect(result.positions['c']!.position.x, closeTo(1, 1e-6));
    expect(result.positions['c']!.position.y, closeTo(3, 1e-6));
  });

  test('a late joining node resolves from three existing anchors', () {
    final observations = [
      range('a', 'b', 4),
      range('a', 'c', math.sqrt(10)),
      range('b', 'c', math.sqrt(18)),
      range('d', 'a', math.sqrt(13)),
      range('d', 'b', math.sqrt(5)),
      range('d', 'c', math.sqrt(5)),
    ];

    final initial = solver.solve(
      activeNodeIds: const ['a', 'b', 'c'],
      observations: observations,
    );
    expect(initial.positions.containsKey('d'), isFalse);

    final joined = solver.solve(
      activeNodeIds: const ['a', 'b', 'c', 'd'],
      observations: observations,
    );
    expect(joined.positions.keys, containsAll(['a', 'b', 'c', 'd']));
    expect(joined.positions['d']!.position.x, closeTo(3, 0.2));
    expect(joined.positions['d']!.position.y, closeTo(2, 0.2));

    final left = solver.solve(
      activeNodeIds: const ['a', 'b', 'c'],
      observations: observations,
    );
    expect(left.positions.containsKey('d'), isFalse);
    expect(left.unresolvedNodeIds, isEmpty);
  });

  test('nodes remain unresolved when distances do not support 2D localization', () {
    final result = solver.solve(
      activeNodeIds: const ['a', 'b', 'c'],
      observations: [range('a', 'b', 2)],
    );

    expect(result.has2DFrame, isFalse);
    expect(result.positions.length, 2);
    expect(result.unresolvedNodeIds, {'c'});
  });
}
