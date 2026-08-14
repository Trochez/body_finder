import 'package:flutter_test/flutter_test.dart';

import 'package:body_finder/application/session/peer_registry.dart';
import 'package:body_finder/domain/geometry/vec2.dart';

void main() {
  test('peer registry stores platform metadata across heartbeats', () {
    final registry = PeerRegistry();

    registry.seen('node-a', 100, platform: 'android');
    registry.seen('node-a', 200);

    final peer = registry.peers.single;
    expect(peer.lastSeenMicros, 200);
    expect(peer.platform, 'android');
    expect(peer.position, isNull);
  });

  test('estimated coordinates are derived without mutating registry identity', () {
    final registry = PeerRegistry();
    registry.seen('node-a', 100, platform: 'linux');

    final estimated = registry.peers.single.withEstimatedPosition(
      const Vec2(3, 4),
      0.25,
    );

    expect(estimated.id, 'node-a');
    expect(estimated.platform, 'linux');
    expect(estimated.position?.x, 3);
    expect(estimated.position?.y, 4);
    expect(estimated.positionSigmaMeters, 0.25);
    expect(registry.peers.single.position, isNull);
  });
}
