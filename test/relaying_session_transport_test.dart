import 'dart:typed_data';

import 'package:body_finder/infrastructure/network/lan_peer_discovery.dart';
import 'package:body_finder/infrastructure/network/relaying_session_transport.dart';
import 'package:body_finder/infrastructure/network/session_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('three nodes converge across a two-segment transport relay', () async {
    final bleSegment = _MemoryBus();
    final lanSegment = _MemoryBus();

    final androidTransport = RelayingSessionTransport(<SessionTransport>[
      _MemoryTransport('bleControl', bleSegment),
    ]);
    final ubuntuTransport = RelayingSessionTransport(<SessionTransport>[
      _MemoryTransport('bleControl', bleSegment),
      _MemoryTransport('lanUdp', lanSegment),
    ]);
    final wslTransport = RelayingSessionTransport(<SessionTransport>[
      _MemoryTransport('lanUdp', lanSegment),
    ]);

    final android = LanPeerDiscovery(
      nodeId: 'aaaaaaaaaaaaaaaa',
      platform: 'android',
      transports: <SessionTransport>[androidTransport],
    );
    final ubuntu = LanPeerDiscovery(
      nodeId: 'bbbbbbbbbbbbbbbb',
      platform: 'linux',
      transports: <SessionTransport>[ubuntuTransport],
    );
    final wsl = LanPeerDiscovery(
      nodeId: 'cccccccccccccccc',
      platform: 'linux',
      transports: <SessionTransport>[wslTransport],
    );

    await android.start();
    await ubuntu.start();
    await wsl.start();
    await Future<void>.delayed(const Duration(milliseconds: 2200));

    expect(android.snapshot.nodeCount, 3);
    expect(ubuntu.snapshot.nodeCount, 3);
    expect(wsl.snapshot.nodeCount, 3);
    expect(android.snapshot.coordinatorId, ubuntu.snapshot.coordinatorId);
    expect(wsl.snapshot.coordinatorId, ubuntu.snapshot.coordinatorId);
    expect(ubuntuTransport.relayedMessageCount, greaterThan(0));
    expect(
      ubuntuTransport.activeChildTransportIds,
      containsAll(<String>{'bleControl', 'lanUdp'}),
    );
    expect(ubuntuTransport.pathStatuses['bleControl'], 'started');
    expect(ubuntuTransport.pathStatuses['lanUdp'], 'started');
    expect(ubuntu.relayedMessageCount, greaterThan(0));
    expect(
      ubuntu.transportPathStatuses,
      containsPair('bleControl', 'started'),
    );

    await android.stop();
    await ubuntu.stop();
    await wsl.stop();
  });

  test('same payload arriving through two paths is delivered once', () async {
    final firstBus = _MemoryBus();
    final secondBus = _MemoryBus();
    final relay = RelayingSessionTransport(<SessionTransport>[
      _MemoryTransport('bleControl', firstBus),
      _MemoryTransport('lanUdp', secondBus),
    ]);

    var delivered = 0;
    await relay.start(onMessage: (_) => delivered++);
    final payload = Uint8List.fromList(<int>[1, 2, 3, 4, 5]);

    firstBus.send(payload);
    secondBus.send(payload);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(delivered, 1);
    expect(relay.duplicateMessageCount, greaterThanOrEqualTo(1));

    await relay.stop();
  });
}

class _MemoryBus {
  final Set<SessionTransportMessageHandler> listeners =
      <SessionTransportMessageHandler>{};

  void send(Uint8List payload) {
    for (final listener in listeners.toList(growable: false)) {
      listener(Uint8List.fromList(payload));
    }
  }
}

class _MemoryTransport implements SessionTransport {
  _MemoryTransport(this.transportId, this.bus);

  final String transportId;
  final _MemoryBus bus;
  SessionTransportMessageHandler? _handler;

  @override
  String get id => transportId;

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
