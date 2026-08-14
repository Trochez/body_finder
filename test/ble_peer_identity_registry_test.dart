import 'package:body_finder/infrastructure/bluetooth/ble_peer_identity_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('normalizes BLE source address and persistent node id', () {
    final registry = BlePeerIdentityRegistry();

    registry.bind(
      sourceKey: '4f:a2:a5:d3:53:9c',
      nodeId: '8F4F4825AABBCCDD',
    );

    expect(
      registry.nodeIdForSource('4F:A2:A5:D3:53:9C'),
      '8f4f4825aabbccdd',
    );
  });

  test('rejects malformed node identity and supports unbind', () {
    final registry = BlePeerIdentityRegistry();

    registry.bind(sourceKey: 'AA:BB:CC:DD:EE:FF', nodeId: 'not-a-node');
    expect(registry.nodeIdForSource('AA:BB:CC:DD:EE:FF'), isNull);

    registry.bind(
      sourceKey: 'AA:BB:CC:DD:EE:FF',
      nodeId: '1234567890abcdef',
    );
    expect(
      registry.nodeIdForSource('aa:bb:cc:dd:ee:ff'),
      '1234567890abcdef',
    );

    registry.unbindSource('aa:bb:cc:dd:ee:ff');
    expect(registry.nodeIdForSource('AA:BB:CC:DD:EE:FF'), isNull);
  });
}
