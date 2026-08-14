import '../../domain/geometry/vec2.dart';

class PeerRecord {
  const PeerRecord({
    required this.id,
    required this.lastSeenMicros,
    this.platform = 'unknown',
    this.position,
    this.positionSigmaMeters,
    this.bootstrapPosition,
  });

  final String id;
  final int lastSeenMicros;
  final String platform;

  /// Defensible physical position derived from real range observations.
  final Vec2? position;
  final double? positionSigmaMeters;

  /// Device-agnostic shared topology position. This is normalized and NON-METRIC.
  /// It must never be consumed by body-localization or physical-distance logic.
  final Vec2? bootstrapPosition;

  bool get hasMetricPosition => position != null;
  bool get hasBootstrapPosition => bootstrapPosition != null;

  PeerRecord withEstimatedPosition(
    Vec2? value,
    double? sigmaMeters, {
    Vec2? bootstrapPosition,
  }) =>
      PeerRecord(
        id: id,
        lastSeenMicros: lastSeenMicros,
        platform: platform,
        position: value,
        positionSigmaMeters: sigmaMeters,
        bootstrapPosition: bootstrapPosition,
      );
}

class PeerRegistry {
  final Map<String, PeerRecord> _peers = {};

  List<PeerRecord> get peers => _peers.values.toList(growable: false);
  int get count => _peers.length;

  void seen(
    String id,
    int nowMicros, {
    String? platform,
  }) {
    final previous = _peers[id];
    _peers[id] = PeerRecord(
      id: id,
      lastSeenMicros: nowMicros,
      platform: platform ?? previous?.platform ?? 'unknown',
    );
  }

  List<String> expireBefore(int cutoffMicros) {
    final expired = _peers.values
        .where((peer) => peer.lastSeenMicros < cutoffMicros)
        .map((peer) => peer.id)
        .toList();
    for (final id in expired) {
      _peers.remove(id);
    }
    return expired;
  }
}
