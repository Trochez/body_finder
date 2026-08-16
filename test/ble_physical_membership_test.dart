import 'dart:convert';
import 'dart:typed_data';

import 'package:body_finder/domain/geometry/range_observation.dart';
import 'package:body_finder/infrastructure/network/lan_peer_discovery.dart';
import 'package:body_finder/infrastructure/network/session_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('direct BLE RSSI observation immediately refreshes peer membership', () async {
    final transport = _RecordingTransport();
    final discovery = LanPeerDiscovery(
      nodeId: 'aaaaaaaaaaaaaaaa',
      platform: 'android',
      transports: <SessionTransport>[transport],
    );

    await discovery.start();
    discovery.publishLocalRange(
      peerNodeId: 'bbbbbbbbbbbbbbbb',
      distanceMeters: 2,
      sigmaMeters: 1,
      source: RangeSource.bleRssi,
    );

    expect(discovery.snapshot.nodeCount, 2);
    expect(
      discovery.snapshot.peers.map((peer) => peer.id),
      contains('bbbbbbbbbbbbbbbb'),
    );

    await discovery.stop();
  });

  test('membership heartbeat is separated from bulk telemetry', () async {
    final transport = _RecordingTransport();
    final discovery = LanPeerDiscovery(
      nodeId: 'aaaaaaaaaaaaaaaa',
      platform: 'android',
      transports: <SessionTransport>[transport],
    );

    await discovery.start();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(transport.payloads.length, greaterThanOrEqualTo(2));
    final membership = jsonDecode(utf8.decode(transport.payloads[0]));
    final telemetry = jsonDecode(utf8.decode(transport.payloads[1]));

    expect(membership['protocol'], LanPeerDiscovery.protocol);
    expect(membership['knownPeers'], isA<List<dynamic>>());
    expect(membership.containsKey('ranges'), isFalse);
    expect(membership.containsKey('rfLinks'), isFalse);

    expect(telemetry['protocol'], LanPeerDiscovery.protocol);
    expect(telemetry.containsKey('knownPeers'), isFalse);
    expect(telemetry['ranges'], isA<List<dynamic>>());
    expect(telemetry['rfLinks'], isA<List<dynamic>>());

    await discovery.stop();
  });
}

class _RecordingTransport implements SessionTransport {
  final List<Uint8List> payloads = <Uint8List>[];
  bool _running = false;

  @override
  String get id => 'recording';

  @override
  bool get isRunning => _running;

  @override
  Future<void> start({
    required SessionTransportMessageHandler onMessage,
    SessionTransportStatusHandler? onStatus,
  }) async {
    _running = true;
    onStatus?.call('started');
  }

  @override
  Future<void> broadcast(Uint8List payload) async {
    payloads.add(Uint8List.fromList(payload));
  }

  @override
  Future<void> stop() async {
    _running = false;
  }
}
