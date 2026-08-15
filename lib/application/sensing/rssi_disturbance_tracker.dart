import 'dart:math' as math;

enum DisturbancePhase {
  idle,
  calibrating,
  monitoring,
  stale,
}

class LinkDisturbance {
  const LinkDisturbance({
    required this.peerNodeId,
    required this.rssiDbm,
    required this.baselineRssiDbm,
    required this.baselineSigmaDb,
    required this.score,
    required this.quality,
    required this.sampleCount,
    required this.age,
  });

  final String peerNodeId;
  final double rssiDbm;
  final double baselineRssiDbm;
  final double baselineSigmaDb;

  /// Experimental RF disturbance index in [0, 1]. This is deliberately not a
  /// probability of a person being present.
  final double score;

  /// Measurement quality in [0, 1], based primarily on baseline stability.
  final double quality;
  final int sampleCount;
  final Duration age;
}

class RssiDisturbanceSnapshot {
  const RssiDisturbanceSnapshot({
    required this.phase,
    required this.requiredPeerIds,
    required this.baselineProgress,
    required this.links,
    required this.overallScore,
    required this.overallQuality,
  });

  final DisturbancePhase phase;
  final Set<String> requiredPeerIds;
  final double baselineProgress;
  final List<LinkDisturbance> links;

  /// Combined experimental RF disturbance index in [0, 1].
  final double overallScore;
  final double overallQuality;

  bool get baselineReady => phase == DisturbancePhase.monitoring;
}

/// Tracks changes in BLE RSSI relative to an explicitly captured baseline.
///
/// This class intentionally detects *change*, not a person. Commodity-phone
/// BLE RSSI is affected by multipath, orientation, movement, obstruction and
/// radio implementation details. A quiet result must never be interpreted as
/// proof that the monitored area is empty.
class RssiDisturbanceTracker {
  RssiDisturbanceTracker({
    this.minimumBaselineSamples = 20,
    this.maximumBaselineSamples = 48,
    this.recentWindowSize = 10,
  })  : assert(minimumBaselineSamples >= 5),
        assert(maximumBaselineSamples >= minimumBaselineSamples),
        assert(recentWindowSize >= 4);

  final int minimumBaselineSamples;
  final int maximumBaselineSamples;
  final int recentWindowSize;

  final Map<String, _LinkState> _links = {};
  Set<String> _requiredPeerIds = const {};
  DisturbancePhase _phase = DisturbancePhase.idle;

  DisturbancePhase get phase => _phase;

  void reset() {
    _links.clear();
    _requiredPeerIds = const {};
    _phase = DisturbancePhase.idle;
  }

  void startCalibration(Iterable<String> peerNodeIds) {
    final peers = peerNodeIds.where((value) => value.isNotEmpty).toSet();
    _links.clear();
    _requiredPeerIds = Set.unmodifiable(peers);
    _phase = peers.isEmpty ? DisturbancePhase.idle : DisturbancePhase.calibrating;
    for (final peer in peers) {
      _links[peer] = _LinkState();
    }
  }

  /// Marks the baseline stale when the physical/session topology changes.
  /// The user must capture a new baseline instead of silently comparing two
  /// different geometries.
  void reconcilePeers(Iterable<String> peerNodeIds) {
    if (_phase == DisturbancePhase.idle) return;
    final peers = peerNodeIds.where((value) => value.isNotEmpty).toSet();
    if (!_setEquals(peers, _requiredPeerIds)) {
      _phase = DisturbancePhase.stale;
    }
  }

  void addSample({
    required String peerNodeId,
    required double rssiDbm,
    DateTime? observedAt,
  }) {
    if (!_requiredPeerIds.contains(peerNodeId) || !rssiDbm.isFinite) return;
    final state = _links.putIfAbsent(peerNodeId, _LinkState.new);
    final now = observedAt ?? DateTime.now();
    state.latestRssi = rssiDbm;
    state.latestAt = now;

    if (_phase == DisturbancePhase.calibrating) {
      if (state.baselineSamples.length < maximumBaselineSamples) {
        state.baselineSamples.add(rssiDbm);
      }
      state.recentSamples
        ..clear()
        ..add(rssiDbm);

      if (_requiredPeerIds.isNotEmpty &&
          _requiredPeerIds.every(
            (peer) => (_links[peer]?.baselineSamples.length ?? 0) >= minimumBaselineSamples,
          )) {
        for (final peer in _requiredPeerIds) {
          _links[peer]!.freezeBaseline();
        }
        _phase = DisturbancePhase.monitoring;
      }
      return;
    }

    if (_phase != DisturbancePhase.monitoring || !state.baselineReady) return;

    state.recentSamples.add(rssiDbm);
    if (state.recentSamples.length > recentWindowSize) {
      state.recentSamples.removeAt(0);
    }

    final sigma = math.max(1.5, state.baselineSigmaDb);
    final levelZ = (rssiDbm - state.baselineMedianDbm).abs() / sigma;
    final levelScore = _unit((levelZ - 1.0) / 4.0);

    // A moving obstruction can increase short-window variability even when
    // the median RSSI remains near its baseline. This term is intentionally
    // conservative and is capped by the same robust baseline scale.
    final recentMad = _mad(state.recentSamples);
    final variabilityRatio = recentMad / sigma;
    final variabilityScore = _unit((variabilityRatio - 0.8) / 2.7);
    final instant = _unit(levelScore * 0.72 + variabilityScore * 0.28);

    // EWMA suppresses one-packet spikes while remaining responsive enough for
    // field experiments with the current ~2 Hz BLE ranging cadence.
    state.smoothedScore = state.scoredSamples == 0
        ? instant
        : state.smoothedScore * 0.72 + instant * 0.28;
    state.scoredSamples++;
  }

  RssiDisturbanceSnapshot snapshot({DateTime? now}) {
    final clock = now ?? DateTime.now();
    var progress = 0.0;
    if (_requiredPeerIds.isNotEmpty) {
      progress = _requiredPeerIds
              .map(
                (peer) => math.min(
                  1.0,
                  (_links[peer]?.baselineSamples.length ?? 0) /
                      minimumBaselineSamples,
                ),
              )
              .reduce(math.min);
    }

    final outputs = <LinkDisturbance>[];
    for (final peer in _requiredPeerIds) {
      final state = _links[peer];
      if (state == null ||
          !state.baselineReady ||
          state.latestRssi == null ||
          state.latestAt == null) {
        continue;
      }
      final quality = _qualityForBaseline(state.baselineSigmaDb);
      outputs.add(
        LinkDisturbance(
          peerNodeId: peer,
          rssiDbm: state.latestRssi!,
          baselineRssiDbm: state.baselineMedianDbm,
          baselineSigmaDb: state.baselineSigmaDb,
          score: _unit(state.smoothedScore),
          quality: quality,
          sampleCount: state.scoredSamples,
          age: clock.difference(state.latestAt!),
        ),
      );
    }
    outputs.sort((left, right) => right.score.compareTo(left.score));

    var combinedNoEvidence = 1.0;
    var weightedQuality = 0.0;
    var qualityWeight = 0.0;
    for (final link in outputs) {
      final fresh = link.age <= const Duration(seconds: 3);
      final q = fresh ? link.quality : 0.0;
      combinedNoEvidence *= 1 - link.score * q;
      weightedQuality += q;
      qualityWeight += 1;
    }

    return RssiDisturbanceSnapshot(
      phase: _phase,
      requiredPeerIds: _requiredPeerIds,
      baselineProgress: _unit(progress),
      links: List.unmodifiable(outputs),
      overallScore: outputs.isEmpty ? 0 : _unit(1 - combinedNoEvidence),
      overallQuality:
          qualityWeight == 0 ? 0 : _unit(weightedQuality / qualityWeight),
    );
  }

  static double _qualityForBaseline(double sigmaDb) {
    // Very unstable baselines are still displayed, but their contribution to
    // the combined disturbance index is deliberately reduced.
    return _unit(1 - (sigmaDb - 1.5) / 8.5);
  }

  static double _median(List<double> values) {
    if (values.isEmpty) return 0;
    final sorted = values.toList()..sort();
    final middle = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[middle];
    return (sorted[middle - 1] + sorted[middle]) / 2;
  }

  static double _mad(List<double> values) {
    if (values.length < 2) return 0;
    final median = _median(values);
    return _median(values.map((value) => (value - median).abs()).toList());
  }

  static double _unit(num value) => value.clamp(0.0, 1.0).toDouble();

  static bool _setEquals(Set<String> left, Set<String> right) =>
      left.length == right.length && left.containsAll(right);
}

class _LinkState {
  final List<double> baselineSamples = [];
  final List<double> recentSamples = [];

  double baselineMedianDbm = 0;
  double baselineSigmaDb = 0;
  double? latestRssi;
  DateTime? latestAt;
  double smoothedScore = 0;
  int scoredSamples = 0;
  bool baselineReady = false;

  void freezeBaseline() {
    baselineMedianDbm = RssiDisturbanceTracker._median(baselineSamples);
    final mad = RssiDisturbanceTracker._mad(baselineSamples);
    // 1.4826 * MAD approximates sigma for Gaussian noise. The floor prevents
    // an unrealistically quiet baseline from turning tiny quantization changes
    // into high anomaly scores.
    baselineSigmaDb = math.max(1.5, 1.4826 * mad);
    recentSamples
      ..clear()
      ..addAll(baselineSamples.skip(math.max(0, baselineSamples.length - 6)));
    baselineReady = true;
  }
}
