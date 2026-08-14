enum RangeSource {
  uwb,
  wifiRtt,
  bleRssi,
  external,
}

class RangeObservation {
  const RangeObservation({
    required this.fromNodeId,
    required this.toNodeId,
    required this.distanceMeters,
    required this.sigmaMeters,
    required this.timestampMicros,
    required this.source,
  });

  final String fromNodeId;
  final String toNodeId;
  final double distanceMeters;
  final double sigmaMeters;
  final int timestampMicros;
  final RangeSource source;

  bool get isValid =>
      fromNodeId.isNotEmpty &&
      toNodeId.isNotEmpty &&
      fromNodeId != toNodeId &&
      distanceMeters.isFinite &&
      distanceMeters > 0 &&
      sigmaMeters.isFinite &&
      sigmaMeters > 0;

  String get normalizedKey => fromNodeId.compareTo(toNodeId) <= 0
      ? '$fromNodeId::$toNodeId'
      : '$toNodeId::$fromNodeId';
}
