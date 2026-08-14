import 'dart:typed_data';

import 'package:body_finder/infrastructure/network/ble_session_framer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fragments and reassembles an arbitrary session payload', () {
    final framer = BleSessionFramer(maxChunkBytes: 20);
    final reassembler = BleSessionReassembler();
    final message = Uint8List.fromList(
      List<int>.generate(237, (index) => index & 0xff),
    );

    final chunks = framer.fragment(message);
    expect(chunks.length, greaterThan(1));
    expect(chunks.every((chunk) => chunk.length <= 20), isTrue);

    Uint8List? completed;
    for (final chunk in chunks.reversed) {
      completed = reassembler.accept(sourceKey: 'peer-a', chunk: chunk) ?? completed;
    }

    expect(completed, orderedEquals(message));
  });

  test('duplicate chunks do not duplicate payload bytes', () {
    final framer = BleSessionFramer(maxChunkBytes: 20);
    final reassembler = BleSessionReassembler();
    final message = Uint8List.fromList(List<int>.generate(40, (index) => index));
    final chunks = framer.fragment(message);

    expect(reassembler.accept(sourceKey: 'peer-a', chunk: chunks.first), isNull);
    expect(reassembler.accept(sourceKey: 'peer-a', chunk: chunks.first), isNull);

    Uint8List? completed;
    for (final chunk in chunks.skip(1)) {
      completed = reassembler.accept(sourceKey: 'peer-a', chunk: chunk) ?? completed;
    }

    expect(completed, orderedEquals(message));
  });

  test('rejects malformed or unrelated chunks', () {
    final reassembler = BleSessionReassembler();

    expect(
      reassembler.accept(
        sourceKey: 'peer-a',
        chunk: Uint8List.fromList(<int>[0, 1, 2, 3, 4, 5, 6]),
      ),
      isNull,
    );
    expect(
      reassembler.accept(
        sourceKey: '',
        chunk: Uint8List.fromList(<int>[0xbf, 1, 0, 1, 0, 1, 5]),
      ),
      isNull,
    );
  });
}
