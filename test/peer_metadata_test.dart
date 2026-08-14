import 'package:flutter_test/flutter_test.dart';

import 'package:body_finder/application/session/peer_registry.dart';
import 'package:body_finder/domain/geometry/vec2.dart';

void main() {
  test('peer registry stores platform and position metadata', () {
    final registry = PeerRegistry();

    registry.seen(
      'node-a',
      100,
      platform: 'android',
      position: const Vec2(1.5, 2.5),
      positionProvided: true,
    );

    final peer = registry.peers.single;
    expect(peer.platform, 'android');
    expect(peer.position?.x, 1.5);
    expect(peer.position?.y, 2.5);
  });

  test('heartbeat preserves metadata when metadata is omitted', () {
    final registry = PeerRegistry();
    registry.seen(
      'node-a',
      100,
      platform: 'linux',
      position: const Vec2(3, 4),
      positionProvided: true,
    );

    registry.seen('node-a', 200);

    final peer = registry.peers.single;
    expect(peer.lastSeenMicros, 200);
    expect(peer.platform, 'linux');
    expect(peer.position?.x, 3);
    expect(peer.position?.y, 4);
  });

  test('explicit null position clears a published coordinate', () {
    final registry = PeerRegistry();
    registry.seen(
      'node-a',
      100,
      position: const Vec2(3, 4),
      positionProvided: true,
    );

    registry.seen(
      'node-a',
      200,
      position: null,
      positionProvided: true,
    );

    expect(registry.peers.single.position, isNull);
  });
}
