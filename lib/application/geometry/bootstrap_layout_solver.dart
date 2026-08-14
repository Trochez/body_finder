import 'dart:math' as math;

import '../../domain/geometry/vec2.dart';

/// Creates a deterministic shared topology layout for any active device set.
///
/// These coordinates are deliberately normalized and NON-METRIC. They exist so
/// every participant can be placed in the shared session UI immediately even
/// when the device exposes no physical ranging source. Body-localization and
/// other metric algorithms must continue to use only range-derived positions.
class BootstrapLayoutSolution {
  const BootstrapLayoutSolution({required this.positions});

  final Map<String, Vec2> positions;

  bool get has2DLayout => positions.length >= 3;
}

class BootstrapLayoutSolver {
  const BootstrapLayoutSolver();

  BootstrapLayoutSolution solve(Iterable<String> activeNodeIds) {
    final ids = activeNodeIds.toSet().toList()..sort();
    if (ids.isEmpty) {
      return const BootstrapLayoutSolution(positions: {});
    }
    if (ids.length == 1) {
      return BootstrapLayoutSolution(
        positions: {ids.first: const Vec2(0, 0)},
      );
    }
    if (ids.length == 2) {
      return BootstrapLayoutSolution(
        positions: {
          ids[0]: const Vec2(-1, 0),
          ids[1]: const Vec2(1, 0),
        },
      );
    }

    final positions = <String, Vec2>{};
    const radius = 1.0;
    for (var index = 0; index < ids.length; index++) {
      // Start at the top of the canvas. Sorting IDs makes every participant
      // independently derive exactly the same topology frame.
      final angle = -math.pi / 2 + (2 * math.pi * index / ids.length);
      positions[ids[index]] = Vec2(
        radius * math.cos(angle),
        radius * math.sin(angle),
      );
    }
    return BootstrapLayoutSolution(positions: positions);
  }
}
