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

  test('compact peer roster converges A-B-C without direct A-C delivery', () async {
    final bus = _LinkedMemoryBus()
      ..connect('a', 'b')
      ..connect('b', 'c');

    final a = LanPeerDiscovery(
      nodeId: 'aaaaaaaaaaaaaaaa',
      platform: 'android',
      transports: <SessionTransport>[_LinkedMemoryTransport(bus, 'a')],
    );
    final b = LanPeerDiscovery(
      nodeId: 'bbbbbbbbbbbbbbbb',
      platform: 'android',
      transports: <SessionTransport>[_LinkedMemoryTransport(bus, 'b')],
    );
    final c = LanPeerDiscovery(
      nodeId: 'cccccccccccccccc',
      platform: 'android',
      transports: <SessionTransport>[_LinkedMemoryTransport(bus, 'c')],
    );

    await a.start();
    await b.start();
    await c.start();

    // A and C never receive each other's payload directly. B's next normal
    // heartbeat advertises the peers whose own heartbeats B has heard, so the
    // endpoints converge without re-broadcasting C's full fragmented payload.
    await Future<void>.delayed(const Duration(milliseconds: 2200));

    expect(bus.directDeliveries('a', 'c'), 0);
    expect(bus.directDeliveries('c', 'a'), 0);
    expect(a.snapshot.nodeCount, 3);
    expect(b.snapshot.nodeCount, 3);
    expect(c.snapshot.nodeCount, 3);
    expect(a.snapshot.peers.map((peer) => peer.id), contains('cccccccccccccccc'));
    expect(c.snapshot.peers.map((peer) => peer.id), contains('aaaaaaaaaaaaaaaa'));

    await a.stop();
    await b.stop();
    await c.stop();
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

class _LinkedMemoryBus {
  final Map<String, SessionTransportMessageHandler> _handlers = {};
  final Map<String, Set<String>> _neighbors = {};
  final Map<String, int> _deliveryCounts = {};

  void connect(String left, String right) {
    _neighbors.putIfAbsent(left, () => <String>{}).add(right);
    _neighbors.putIfAbsent(right, () => <String>{}).add(left);
  }

  void register(String endpoint, SessionTransportMessageHandler handler) {
    _handlers[endpoint] = handler;
  }

  void unregister(String endpoint) {
    _handlers.remove(endpoint);
  }

  void send(String source, Uint8List payload) {
    for (final target in _neighbors[source] ?? const <String>{}) {
      final handler = _handlers[target];
      if (handler == null) continue;
      _deliveryCounts['$source->$target'] =
          (_deliveryCounts['$source->$target'] ?? 0) + 1;
      handler(Uint8List.fromList(payload));
    }
  }

  int directDeliveries(String source, String target) =>
      _deliveryCounts['$source->$target'] ?? 0;
}

class _LinkedMemoryTransport implements SessionTransport {
  _LinkedMemoryTransport(this.bus, this.endpoint);

  final _LinkedMemoryBus bus;
  final String endpoint;
  SessionTransportMessageHandler? _handler;

  @override
  String get id => 'linkedMemory';

  @override
  bool get isRunning => _handler != null;

  @override
  Future<void> start({
    required SessionTransportMessageHandler onMessage,
    SessionTransportStatusHandler? onStatus,
  }) async {
    _handler = onMessage;
    bus.register(endpoint, onMessage);
    onStatus?.call('started');
  }

  @override
  Future<void> broadcast(Uint8List payload) async => bus.send(endpoint, payload);

  @override
  Future<void> stop() async {
    bus.unregister(endpoint);
    _handler = null;
  }
}
