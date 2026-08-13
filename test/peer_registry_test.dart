import 'package:body_finder/application/session/peer_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('participating phone count changes without restarting a session', () {
    final registry = PeerRegistry();
    registry.seen('a', 100);
    registry.seen('b', 120);
    expect(registry.count, 2);

    registry.seen('c', 130);
    expect(registry.count, 3);

    final expired = registry.expireBefore(115);
    expect(expired, ['a']);
    expect(registry.count, 2);
  });
}
