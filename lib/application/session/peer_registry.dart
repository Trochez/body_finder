import '../../domain/geometry/vec2.dart';

class PeerRecord {
  const PeerRecord({
    required this.id,
    required this.lastSeenMicros,
    this.platform = 'unknown',
    this.position,
  });

  final String id;
  final int lastSeenMicros;
  final String platform;
  final Vec2? position;
}

class PeerRegistry {
  final Map<String, PeerRecord> _peers = {};

  List<PeerRecord> get peers => _peers.values.toList(growable: false);
  int get count => _peers.length;

  void seen(
    String id,
    int nowMicros, {
    String? platform,
    Vec2? position,
    bool positionProvided = false,
  }) {
    final previous = _peers[id];
    _peers[id] = PeerRecord(
      id: id,
      lastSeenMicros: nowMicros,
      platform: platform ?? previous?.platform ?? 'unknown',
      position: positionProvided ? position : previous?.position,
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
