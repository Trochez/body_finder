class PhysicalRangeTelemetry {
  const PhysicalRangeTelemetry({
    required this.peerNodeId,
    required this.source,
    required this.distanceMeters,
    required this.sigmaMeters,
    required this.observedAtMicros,
    this.rssiDbm,
  });

  final String peerNodeId;
  final String source;
  final double distanceMeters;
  final double sigmaMeters;
  final double? rssiDbm;
  final int observedAtMicros;
}

class SessionValidationReport {
  const SessionValidationReport({
    required this.observedNodeIds,
    required this.observedTransportIds,
    required this.maxNodeCount,
    required this.maxMetricNodeCount,
    required this.maxRangeEdgeCount,
    required this.rangeSampleCount,
    required this.latestRangesByPeer,
    required this.minDistanceMeters,
    required this.maxDistanceMeters,
    required this.minRssiDbm,
    required this.maxRssiDbm,
    required this.relayedMessageCount,
    required this.duplicateMessageCount,
  });

  final Set<String> observedNodeIds;
  final Set<String> observedTransportIds;
  final int maxNodeCount;
  final int maxMetricNodeCount;
  final int maxRangeEdgeCount;
  final int rangeSampleCount;
  final Map<String, PhysicalRangeTelemetry> latestRangesByPeer;
  final double? minDistanceMeters;
  final double? maxDistanceMeters;
  final double? minRssiDbm;
  final double? maxRssiDbm;
  final int relayedMessageCount;
  final int duplicateMessageCount;

  String toPlainText() {
    String value(double? number, String unit) => number == null
        ? 'not observed'
        : '${number.toStringAsFixed(2)} $unit';

    return <String>[
      'BODY FINDER VALIDATION OBSERVATIONS',
      'Nodes observed: ${observedNodeIds.length}',
      'Maximum simultaneous nodes: $maxNodeCount',
      'Transports observed: ${observedTransportIds.isEmpty ? 'none' : observedTransportIds.join(', ')}',
      'Maximum physical range edges: $maxRangeEdgeCount',
      'Maximum metric nodes: $maxMetricNodeCount',
      'Physical range samples: $rangeSampleCount',
      'Distance min: ${value(minDistanceMeters, 'm')}',
      'Distance max: ${value(maxDistanceMeters, 'm')}',
      'RSSI min: ${value(minRssiDbm, 'dBm')}',
      'RSSI max: ${value(maxRssiDbm, 'dBm')}',
      'Relayed messages: $relayedMessageCount',
      'Duplicate messages suppressed: $duplicateMessageCount',
      'Note: observations are diagnostics, not proof of body presence or absence.',
    ].join('\n');
  }
}

/// Collects deterministic facts from one physical validation session.
///
/// The recorder intentionally does not infer PASS/FAIL for features it cannot
/// directly observe. Higher-level acceptance logic can evaluate this report
/// against a test plan without turning missing evidence into a false claim.
class SessionValidationRecorder {
  final Set<String> _observedNodeIds = <String>{};
  final Set<String> _observedTransportIds = <String>{};
  final Map<String, PhysicalRangeTelemetry> _latestRangesByPeer =
      <String, PhysicalRangeTelemetry>{};

  int _maxNodeCount = 0;
  int _maxMetricNodeCount = 0;
  int _maxRangeEdgeCount = 0;
  int _rangeSampleCount = 0;
  double? _minDistanceMeters;
  double? _maxDistanceMeters;
  double? _minRssiDbm;
  double? _maxRssiDbm;
  int _relayedMessageCount = 0;
  int _duplicateMessageCount = 0;

  void recordTopology({
    required Iterable<String> nodeIds,
    required int metricNodeCount,
    required int rangeEdgeCount,
  }) {
    final ids = nodeIds.where((id) => id.isNotEmpty).toSet();
    _observedNodeIds.addAll(ids);
    if (ids.length > _maxNodeCount) _maxNodeCount = ids.length;
    if (metricNodeCount > _maxMetricNodeCount) {
      _maxMetricNodeCount = metricNodeCount;
    }
    if (rangeEdgeCount > _maxRangeEdgeCount) {
      _maxRangeEdgeCount = rangeEdgeCount;
    }
  }

  void recordTransports(Iterable<String> transportIds) {
    _observedTransportIds.addAll(
      transportIds.where((id) => id.isNotEmpty),
    );
  }

  void recordPhysicalRange({
    required String peerNodeId,
    required String source,
    required double distanceMeters,
    required double sigmaMeters,
    double? rssiDbm,
    int? observedAtMicros,
  }) {
    if (peerNodeId.isEmpty || source.isEmpty) return;
    if (!distanceMeters.isFinite || distanceMeters <= 0) return;
    if (!sigmaMeters.isFinite || sigmaMeters <= 0) return;
    if (rssiDbm != null && !rssiDbm.isFinite) return;

    final sample = PhysicalRangeTelemetry(
      peerNodeId: peerNodeId,
      source: source,
      distanceMeters: distanceMeters,
      sigmaMeters: sigmaMeters,
      rssiDbm: rssiDbm,
      observedAtMicros:
          observedAtMicros ?? DateTime.now().microsecondsSinceEpoch,
    );
    _latestRangesByPeer[peerNodeId] = sample;
    _rangeSampleCount++;

    _minDistanceMeters = _minDistanceMeters == null
        ? distanceMeters
        : (_minDistanceMeters! < distanceMeters
            ? _minDistanceMeters
            : distanceMeters);
    _maxDistanceMeters = _maxDistanceMeters == null
        ? distanceMeters
        : (_maxDistanceMeters! > distanceMeters
            ? _maxDistanceMeters
            : distanceMeters);

    if (rssiDbm != null) {
      _minRssiDbm = _minRssiDbm == null
          ? rssiDbm
          : (_minRssiDbm! < rssiDbm ? _minRssiDbm : rssiDbm);
      _maxRssiDbm = _maxRssiDbm == null
          ? rssiDbm
          : (_maxRssiDbm! > rssiDbm ? _maxRssiDbm : rssiDbm);
    }
  }

  void recordRelayStatistics({
    required int relayedMessageCount,
    required int duplicateMessageCount,
  }) {
    if (relayedMessageCount > _relayedMessageCount) {
      _relayedMessageCount = relayedMessageCount;
    }
    if (duplicateMessageCount > _duplicateMessageCount) {
      _duplicateMessageCount = duplicateMessageCount;
    }
  }

  SessionValidationReport get report => SessionValidationReport(
        observedNodeIds: Set<String>.unmodifiable(_observedNodeIds),
        observedTransportIds:
            Set<String>.unmodifiable(_observedTransportIds),
        maxNodeCount: _maxNodeCount,
        maxMetricNodeCount: _maxMetricNodeCount,
        maxRangeEdgeCount: _maxRangeEdgeCount,
        rangeSampleCount: _rangeSampleCount,
        latestRangesByPeer: Map<String, PhysicalRangeTelemetry>.unmodifiable(
          _latestRangesByPeer,
        ),
        minDistanceMeters: _minDistanceMeters,
        maxDistanceMeters: _maxDistanceMeters,
        minRssiDbm: _minRssiDbm,
        maxRssiDbm: _maxRssiDbm,
        relayedMessageCount: _relayedMessageCount,
        duplicateMessageCount: _duplicateMessageCount,
      );

  void reset() {
    _observedNodeIds.clear();
    _observedTransportIds.clear();
    _latestRangesByPeer.clear();
    _maxNodeCount = 0;
    _maxMetricNodeCount = 0;
    _maxRangeEdgeCount = 0;
    _rangeSampleCount = 0;
    _minDistanceMeters = null;
    _maxDistanceMeters = null;
    _minRssiDbm = null;
    _maxRssiDbm = null;
    _relayedMessageCount = 0;
    _duplicateMessageCount = 0;
  }
}
