import 'dart:typed_data';

import 'package:body_finder/infrastructure/network/lan_peer_discovery.dart';
import 'package:body_finder/infrastructure/network/session_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('peer session converges over a non-LAN transport', () async {
    final bus = _MemoryBus();
    final first = LanPeerDiscovery(
      nodeId: 'aaaaaaaaaaaaaaaa',
      platform: 'android',
      transports: <SessionTransport>[_MemoryTransport(bus)],
    );
    final second = LanPeerDiscovery(
      nodeId: 'bbbbbbbbbbbbbbbb',
      platform: 'linux',
      transports: <SessionTransport>[_MemoryTransport(bus)],
    );

    await first.start();
    await second.start();

    // The first node may have sent its initial announcement before the second
    // transport subscribed. Allow one normal heartbeat interval for both
    // registries to converge, matching real late-join behavior.
    await Future<void>.delayed(const Duration(milliseconds: 1100));

    expect(first.snapshot.nodeCount, 2);
    expect(second.snapshot.nodeCount, 2);
    expect(first.activeTransportIds, contains('memory'));
    expect(second.activeTransportIds, contains('memory'));
    expect(first.snapshot.coordinatorId, second.snapshot.coordinatorId);

    await first.stop();
    await second.stop();
  });
}

class _MemoryBus {
  final Set<SessionTransportMessageHandler> listeners = {};

  void send(Uint8List payload) {
    for (final listener in listeners.toList(growable: false)) {
      listener(Uint8List.fromList(payload));
    }
  }
}

class _MemoryTransport implements SessionTransport {
  _MemoryTransport(this.bus);

  final _MemoryBus bus;
  SessionTransportMessageHandler? _handler;

  @override
  String get id => 'memory';

  @override
  bool get isRunning => _handler != null;

  @override
  Future<void> start({
    required SessionTransportMessageHandler onMessage,
    SessionTransportStatusHandler? onStatus,
  }) async {
    _handler = onMessage;
    bus.listeners.add(onMessage);
    onStatus?.call('started');
  }

  @override
  Future<void> broadcast(Uint8List payload) async => bus.send(payload);

  @override
  Future<void> stop() async {
    final handler = _handler;
    if (handler != null) bus.listeners.remove(handler);
    _handler = null;
  }
}
