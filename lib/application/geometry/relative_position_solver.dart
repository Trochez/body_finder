import 'dart:math' as math;

import '../../domain/geometry/range_observation.dart';
import '../../domain/geometry/vec2.dart';

class EstimatedNodePosition {
  const EstimatedNodePosition({
    required this.nodeId,
    required this.position,
    required this.sigmaMeters,
  });

  final String nodeId;
  final Vec2 position;
  final double sigmaMeters;
}

class RelativePositionSolution {
  const RelativePositionSolution({
    required this.positions,
    required this.unresolvedNodeIds,
    required this.observationCount,
  });

  final Map<String, EstimatedNodePosition> positions;
  final Set<String> unresolvedNodeIds;
  final int observationCount;

  bool get has2DFrame => positions.length >= 3;
}

class RelativePositionSolver {
  const RelativePositionSolver();

  RelativePositionSolution solve({
    required Iterable<String> activeNodeIds,
    required Iterable<RangeObservation> observations,
  }) {
    final active = activeNodeIds.toSet();
    final best = <String, RangeObservation>{};
    for (final observation in observations) {
      if (!observation.isValid ||
          !active.contains(observation.fromNodeId) ||
          !active.contains(observation.toNodeId)) {
        continue;
      }
      final previous = best[observation.normalizedKey];
      if (previous == null ||
          observation.timestampMicros > previous.timestampMicros ||
          (observation.timestampMicros == previous.timestampMicros &&
              observation.sigmaMeters < previous.sigmaMeters)) {
        best[observation.normalizedKey] = observation;
      }
    }

    final positions = <String, EstimatedNodePosition>{};
    if (active.isEmpty) {
      return const RelativePositionSolution(
        positions: {},
        unresolvedNodeIds: {},
        observationCount: 0,
      );
    }

    final ids = active.toList()..sort();
    if (ids.length == 1) {
      positions[ids.first] = EstimatedNodePosition(
        nodeId: ids.first,
        position: const Vec2(0, 0),
        sigmaMeters: double.infinity,
      );
      return RelativePositionSolution(
        positions: positions,
        unresolvedNodeIds: const {},
        observationCount: best.length,
      );
    }

    final seed = _bestTriangle(ids, best);
    if (seed != null) {
      _seedTriangle(seed, best, positions);
    } else {
      final baseline = _bestBaseline(ids, best);
      if (baseline != null) {
        final r = _range(baseline.$1, baseline.$2, best)!;
        positions[baseline.$1] = EstimatedNodePosition(
          nodeId: baseline.$1,
          position: const Vec2(0, 0),
          sigmaMeters: r.sigmaMeters,
        );
        positions[baseline.$2] = EstimatedNodePosition(
          nodeId: baseline.$2,
          position: Vec2(r.distanceMeters, 0),
          sigmaMeters: r.sigmaMeters,
        );
      }
    }

    var progress = true;
    while (progress) {
      progress = false;
      for (final nodeId in ids) {
        if (positions.containsKey(nodeId)) continue;
        final anchors = positions.values
            .map((position) {
              final range = _range(nodeId, position.nodeId, best);
              return range == null ? null : (position, range);
            })
            .whereType<(EstimatedNodePosition, RangeObservation)>()
            .toList();
        if (anchors.length < 3) continue;
        final estimate = _fitFromAnchors(nodeId, anchors);
        if (estimate != null) {
          positions[nodeId] = estimate;
          progress = true;
        }
      }
    }

    return RelativePositionSolution(
      positions: positions,
      unresolvedNodeIds: active.difference(positions.keys.toSet()),
      observationCount: best.length,
    );
  }

  (String, String, String)? _bestTriangle(
    List<String> ids,
    Map<String, RangeObservation> ranges,
  ) {
    (String, String, String)? bestTriangle;
    var bestScore = double.infinity;
    for (var i = 0; i < ids.length - 2; i++) {
      for (var j = i + 1; j < ids.length - 1; j++) {
        for (var k = j + 1; k < ids.length; k++) {
          final ab = _range(ids[i], ids[j], ranges);
          final ac = _range(ids[i], ids[k], ranges);
          final bc = _range(ids[j], ids[k], ranges);
          if (ab == null || ac == null || bc == null) continue;
          if (!_validTriangle(ab.distanceMeters, ac.distanceMeters, bc.distanceMeters)) {
            continue;
          }
          final score = ab.sigmaMeters + ac.sigmaMeters + bc.sigmaMeters;
          if (score < bestScore) {
            bestScore = score;
            bestTriangle = (ids[i], ids[j], ids[k]);
          }
        }
      }
    }
    return bestTriangle;
  }

  void _seedTriangle(
    (String, String, String) seed,
    Map<String, RangeObservation> ranges,
    Map<String, EstimatedNodePosition> output,
  ) {
    final a = seed.$1;
    final b = seed.$2;
    final c = seed.$3;
    final ab = _range(a, b, ranges)!;
    final ac = _range(a, c, ranges)!;
    final bc = _range(b, c, ranges)!;
    final d = ab.distanceMeters;
    final x = (ac.distanceMeters * ac.distanceMeters -
            bc.distanceMeters * bc.distanceMeters +
            d * d) /
        (2 * d);
    final y2 = math.max(0.0, ac.distanceMeters * ac.distanceMeters - x * x);
    final y = math.sqrt(y2);
    final sigma = (ab.sigmaMeters + ac.sigmaMeters + bc.sigmaMeters) / 3;
    output[a] = EstimatedNodePosition(
      nodeId: a,
      position: const Vec2(0, 0),
      sigmaMeters: sigma,
    );
    output[b] = EstimatedNodePosition(
      nodeId: b,
      position: Vec2(d, 0),
      sigmaMeters: sigma,
    );
    output[c] = EstimatedNodePosition(
      nodeId: c,
      position: Vec2(x, y),
      sigmaMeters: sigma,
    );
  }

  EstimatedNodePosition? _fitFromAnchors(
    String nodeId,
    List<(EstimatedNodePosition, RangeObservation)> anchors,
  ) {
    var estimate = const Vec2(0, 0);
    var weightSum = 0.0;
    for (final anchor in anchors) {
      final weight = 1 / math.max(0.01, anchor.$2.sigmaMeters * anchor.$2.sigmaMeters);
      estimate = estimate + anchor.$1.position * weight;
      weightSum += weight;
    }
    estimate = estimate * (1 / weightSum);

    for (var iteration = 0; iteration < 120; iteration++) {
      var gx = 0.0;
      var gy = 0.0;
      var totalWeight = 0.0;
      for (final anchor in anchors) {
        final delta = estimate - anchor.$1.position;
        final distance = math.max(1e-6, delta.norm);
        final residual = distance - anchor.$2.distanceMeters;
        final weight = 1 / math.max(0.01, anchor.$2.sigmaMeters * anchor.$2.sigmaMeters);
        gx += weight * residual * delta.x / distance;
        gy += weight * residual * delta.y / distance;
        totalWeight += weight;
      }
      final step = 0.18 / math.max(1.0, totalWeight);
      estimate = Vec2(estimate.x - step * gx, estimate.y - step * gy);
    }

    var weightedError = 0.0;
    var weightSum2 = 0.0;
    var sigmaSum = 0.0;
    for (final anchor in anchors) {
      final residual = estimate.distanceTo(anchor.$1.position) - anchor.$2.distanceMeters;
      final weight = 1 / math.max(0.01, anchor.$2.sigmaMeters * anchor.$2.sigmaMeters);
      weightedError += weight * residual * residual;
      weightSum2 += weight;
      sigmaSum += anchor.$2.sigmaMeters;
    }
    final residualRms = math.sqrt(weightedError / math.max(1e-9, weightSum2));
    final sigma = residualRms + sigmaSum / anchors.length;
    if (!estimate.x.isFinite || !estimate.y.isFinite || !sigma.isFinite) return null;
    return EstimatedNodePosition(
      nodeId: nodeId,
      position: estimate,
      sigmaMeters: sigma,
    );
  }

  (String, String)? _bestBaseline(
    List<String> ids,
    Map<String, RangeObservation> ranges,
  ) {
    (String, String)? result;
    var bestSigma = double.infinity;
    for (var i = 0; i < ids.length - 1; i++) {
      for (var j = i + 1; j < ids.length; j++) {
        final observation = _range(ids[i], ids[j], ranges);
        if (observation != null && observation.sigmaMeters < bestSigma) {
          bestSigma = observation.sigmaMeters;
          result = (ids[i], ids[j]);
        }
      }
    }
    return result;
  }

  RangeObservation? _range(
    String a,
    String b,
    Map<String, RangeObservation> ranges,
  ) {
    final key = a.compareTo(b) <= 0 ? '$a::$b' : '$b::$a';
    return ranges[key];
  }

  bool _validTriangle(double a, double b, double c) =>
      a + b > c && a + c > b && b + c > a;
}
