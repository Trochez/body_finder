import 'dart:typed_data';

class BleSessionFramer {
  BleSessionFramer({this.maxChunkBytes = 20}) {
    if (maxChunkBytes <= headerBytes) {
      throw ArgumentError.value(
        maxChunkBytes,
        'maxChunkBytes',
        'Must leave room for a BLE session payload.',
      );
    }
  }

  static const int magic = 0xbf;
  static const int version = 1;
  static const int headerBytes = 6;

  final int maxChunkBytes;
  int _nextMessageId = 0;

  List<Uint8List> fragment(Uint8List message) {
    if (message.isEmpty) return const <Uint8List>[];
    final payloadBytes = maxChunkBytes - headerBytes;
    final count = (message.length + payloadBytes - 1) ~/ payloadBytes;
    if (count > 255) {
      throw ArgumentError.value(
        message.length,
        'message',
        'Message requires more than 255 BLE chunks.',
      );
    }

    final messageId = _nextMessageId;
    _nextMessageId = (_nextMessageId + 1) & 0xffff;
    final result = <Uint8List>[];
    for (var index = 0; index < count; index++) {
      final start = index * payloadBytes;
      final candidateEnd = start + payloadBytes;
      final end = candidateEnd < message.length ? candidateEnd : message.length;
      final chunk = Uint8List(headerBytes + end - start);
      chunk[0] = magic;
      chunk[1] = version;
      chunk[2] = (messageId >> 8) & 0xff;
      chunk[3] = messageId & 0xff;
      chunk[4] = index;
      chunk[5] = count;
      chunk.setRange(headerBytes, chunk.length, message, start);
      result.add(chunk);
    }
    return result;
  }
}

class BleSessionReassembler {
  BleSessionReassembler({
    this.bufferTtl = const Duration(seconds: 15),
  });

  final Duration bufferTtl;
  final Map<String, _PendingMessage> _pending = <String, _PendingMessage>{};

  /// Returns a complete session payload when the received chunk completes one
  /// message. Chunks may arrive out of order or be duplicated.
  Uint8List? accept({
    required String sourceKey,
    required Uint8List chunk,
    DateTime? now,
  }) {
    final timestamp = now ?? DateTime.now();
    _expire(timestamp);
    if (sourceKey.isEmpty || chunk.length <= BleSessionFramer.headerBytes) {
      return null;
    }
    if (chunk[0] != BleSessionFramer.magic ||
        chunk[1] != BleSessionFramer.version) {
      return null;
    }

    final messageId = (chunk[2] << 8) | chunk[3];
    final chunkIndex = chunk[4];
    final chunkCount = chunk[5];
    if (chunkCount == 0 || chunkIndex >= chunkCount) return null;

    final key = '$sourceKey:$messageId';
    var pending = _pending[key];
    if (pending == null || pending.chunkCount != chunkCount) {
      pending = _PendingMessage(chunkCount: chunkCount, lastUpdated: timestamp);
      _pending[key] = pending;
    }
    pending.lastUpdated = timestamp;
    pending.chunks.putIfAbsent(
      chunkIndex,
      () => Uint8List.fromList(
        chunk.sublist(BleSessionFramer.headerBytes),
      ),
    );

    if (pending.chunks.length != chunkCount) return null;
    final ordered = <int>[];
    for (var index = 0; index < chunkCount; index++) {
      final bytes = pending.chunks[index];
      if (bytes == null) return null;
      ordered.addAll(bytes);
    }
    _pending.remove(key);
    return Uint8List.fromList(ordered);
  }

  void clear() => _pending.clear();

  void _expire(DateTime now) {
    final cutoff = now.subtract(bufferTtl);
    _pending.removeWhere((_, value) => value.lastUpdated.isBefore(cutoff));
  }
}

class _PendingMessage {
  _PendingMessage({
    required this.chunkCount,
    required this.lastUpdated,
  });

  final int chunkCount;
  DateTime lastUpdated;
  final Map<int, Uint8List> chunks = <int, Uint8List>{};
}
