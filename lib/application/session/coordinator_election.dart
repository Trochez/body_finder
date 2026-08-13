import 'peer_registry.dart';

String? electCoordinator(Iterable<PeerRecord> peers) {
  final ids = peers.map((peer) => peer.id).toList()..sort();
  return ids.isEmpty ? null : ids.first;
}
