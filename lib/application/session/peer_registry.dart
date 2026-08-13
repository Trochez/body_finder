class PeerRecord {
  const PeerRecord({required this.id, required this.lastSeenMicros});
  final String id;
  final int lastSeenMicros;
}

class PeerRegistry {
  final Map<String, PeerRecord> _peers = {};

  List<PeerRecord> get peers => _peers.values.toList(growable: false);
  int get count => _peers.length;

  void seen(String id, int nowMicros) {
    _peers[id] = PeerRecord(id: id, lastSeenMicros: nowMicros);
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
