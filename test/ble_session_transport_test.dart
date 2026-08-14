import 'dart:convert';
import 'dart:typed_data';

import 'package:body_finder/infrastructure/network/ble_session_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('broadcast fragments and inbound chunks reassemble once', () async {
    final platform = _FakeBleSessionPlatformAdapter();
    final transport = BleSessionTransport(
      nodeId: 'aaaaaaaaaaaaaaaa',
      platformAdapter: platform,
    );
    final received = <Uint8List>[];

    await transport.start(onMessage: received.add);
    final message = Uint8List.fromList(
      List<int>.generate(100, (index) => index & 0xff),
    );
    await transport.broadcast(message);

    expect(platform.sentChunks.length, greaterThan(1));
    for (final chunk in platform.sentChunks.reversed) {
      platform.emit('peer-1', chunk);
    }

    expect(received, hasLength(1));
    expect(received.single, orderedEquals(message));
    await transport.stop();
  });

  test('failed platform start causes the BLE child transport to fail cleanly', () async {
    final platform = _FakeBleSessionPlatformAdapter(startStatus: 'unsupported');
    final transport = BleSessionTransport(
      nodeId: 'aaaaaaaaaaaaaaaa',
      platformAdapter: platform,
    );

    await expectLater(
      transport.start(onMessage: (_) {}),
      throwsA(isA<StateError>()),
    );
    expect(transport.isRunning, isFalse);
  });

  test('reassembly remains separate for different BLE source keys', () async {
    final platform = _FakeBleSessionPlatformAdapter();
    final transport = BleSessionTransport(
      nodeId: 'aaaaaaaaaaaaaaaa',
      platformAdapter: platform,
    );
    final received = <Uint8List>[];
    await transport.start(onMessage: received.add);

    final first = Uint8List.fromList(List<int>.generate(50, (index) => index));
    final second = Uint8List.fromList(List<int>.generate(50, (index) => 100 + index));
    await transport.broadcast(first);
    final firstChunks = platform.sentChunks.toList(growable: false);
    platform.sentChunks.clear();
    await transport.broadcast(second);
    final secondChunks = platform.sentChunks.toList(growable: false);

    final max = firstChunks.length > secondChunks.length
        ? firstChunks.length
        : secondChunks.length;
    for (var index = 0; index < max; index++) {
      if (index < firstChunks.length) platform.emit('peer-a', firstChunks[index]);
      if (index < secondChunks.length) platform.emit('peer-b', secondChunks[index]);
    }

    expect(received, hasLength(2));
    expect(received[0], orderedEquals(first));
    expect(received[1], orderedEquals(second));
    await transport.stop();
  });

  test('binds transport source to persistent node id from complete session payload', () async {
    final platform = _IdentityBindingFakeBleSessionPlatformAdapter();
    final transport = BleSessionTransport(
      nodeId: 'aaaaaaaaaaaaaaaa',
      platformAdapter: platform,
    );
    final received = <Uint8List>[];
    await transport.start(onMessage: received.add);

    final payload = Uint8List.fromList(
      utf8.encode(
        jsonEncode(<String, Object>{
          'protocol': 'body_finder_peer_v1',
          'nodeId': '8f4f4825aabbccdd',
          'platform': 'android',
          'timestampMicros': 1,
          'ranges': const <Object>[],
        }),
      ),
    );
    await transport.broadcast(payload);
    final chunks = platform.sentChunks.toList(growable: false);
    platform.sentChunks.clear();
    for (final chunk in chunks) {
      platform.emit('4F:A2:A5:D3:53:9C', chunk);
    }

    expect(received, hasLength(1));
    expect(platform.boundSourceKey, '4F:A2:A5:D3:53:9C');
    expect(platform.boundNodeId, '8f4f4825aabbccdd');
    await transport.stop();
  });
}

class _FakeBleSessionPlatformAdapter implements BleSessionPlatformAdapter {
  _FakeBleSessionPlatformAdapter({this.startStatus = 'started'});

  final String startStatus;
  final List<Uint8List> sentChunks = <Uint8List>[];
  BleSessionChunkHandler? _onChunk;
  bool _running = false;

  @override
  bool get isRunning => _running;

  @override
  Future<String> start({
    required String nodeId,
    required BleSessionChunkHandler onChunk,
    BleSessionPlatformStatusHandler? onStatus,
  }) async {
    _onChunk = onChunk;
    _running = startStatus == 'started' || startStatus == 'gattReady';
    onStatus?.call(startStatus);
    return startStatus;
  }

  @override
  Future<void> sendChunk(Uint8List chunk) async {
    sentChunks.add(Uint8List.fromList(chunk));
  }

  @override
  Future<void> stop() async {
    _running = false;
    _onChunk = null;
  }

  void emit(String sourceKey, Uint8List chunk) {
    _onChunk?.call(
      BleSessionChunk(
        sourceKey: sourceKey,
        bytes: Uint8List.fromList(chunk),
      ),
    );
  }
}

class _IdentityBindingFakeBleSessionPlatformAdapter
    extends _FakeBleSessionPlatformAdapter
    implements BleSessionPeerIdentityBinder {
  String? boundSourceKey;
  String? boundNodeId;

  @override
  void bindPeerIdentity({required String sourceKey, required String nodeId}) {
    boundSourceKey = sourceKey;
    boundNodeId = nodeId;
  }
}
