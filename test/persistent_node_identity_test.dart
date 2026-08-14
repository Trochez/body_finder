import 'package:body_finder/infrastructure/identity/persistent_node_identity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reuses the same valid node id across launches', () async {
    final store = _MemoryStore('0123456789abcdef');
    final identity = PersistentNodeIdentity(
      store: store,
      generator: () => '1111111111111111',
    );

    expect(await identity.loadOrCreate(), '0123456789abcdef');
    expect(store.writes, isEmpty);
  });

  test('creates and stores an id on first launch', () async {
    final store = _MemoryStore(null);
    final identity = PersistentNodeIdentity(
      store: store,
      generator: () => 'abcdef0123456789',
    );

    expect(await identity.loadOrCreate(), 'abcdef0123456789');
    expect(store.value, 'abcdef0123456789');
    expect(store.writes, ['abcdef0123456789']);
  });

  test('replaces corrupt persisted identity', () async {
    final store = _MemoryStore('not-a-node-id');
    final identity = PersistentNodeIdentity(
      store: store,
      generator: () => 'fedcba9876543210',
    );

    expect(await identity.loadOrCreate(), 'fedcba9876543210');
    expect(store.value, 'fedcba9876543210');
  });

  test('storage failure does not prevent session identity creation', () async {
    var sequence = 0;
    final identity = PersistentNodeIdentity(
      store: _FailingStore(),
      generator: () => sequence++ == 0
          ? '1111111111111111'
          : '2222222222222222',
    );

    expect(await identity.loadOrCreate(), '1111111111111111');
  });

  test('validity requires exactly sixteen hexadecimal characters', () {
    expect(PersistentNodeIdentity.isValid('0123456789abcdef'), isTrue);
    expect(PersistentNodeIdentity.isValid('ABCDEF0123456789'), isTrue);
    expect(PersistentNodeIdentity.isValid('0123'), isFalse);
    expect(PersistentNodeIdentity.isValid('gggggggggggggggg'), isFalse);
    expect(PersistentNodeIdentity.isValid(null), isFalse);
  });
}

class _MemoryStore implements NodeIdentityStore {
  _MemoryStore(this.value);

  String? value;
  final List<String> writes = [];

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async {
    this.value = value;
    writes.add(value);
  }
}

class _FailingStore implements NodeIdentityStore {
  @override
  Future<String?> read() async => throw StateError('storage unavailable');

  @override
  Future<void> write(String value) async => throw StateError('storage unavailable');
}
