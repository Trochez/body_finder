import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

abstract class NodeIdentityStore {
  Future<String?> read();
  Future<void> write(String value);
}

class SharedPreferencesNodeIdentityStore implements NodeIdentityStore {
  SharedPreferencesNodeIdentityStore({SharedPreferencesAsync? preferences})
      : _preferences = preferences ?? SharedPreferencesAsync();

  static const _key = 'body_finder_node_id_v1';
  final SharedPreferencesAsync _preferences;

  @override
  Future<String?> read() => _preferences.getString(_key);

  @override
  Future<void> write(String value) => _preferences.setString(_key, value);
}

class PersistentNodeIdentity {
  PersistentNodeIdentity({
    NodeIdentityStore? store,
    String Function()? generator,
  })  : _store = store ?? SharedPreferencesNodeIdentityStore(),
        _generator = generator ?? _newNodeId;

  final NodeIdentityStore _store;
  final String Function() _generator;

  Future<String> loadOrCreate() async {
    try {
      final existing = await _store.read();
      if (isValid(existing)) return existing!.toLowerCase();

      final generated = _generator().toLowerCase();
      if (!isValid(generated)) {
        throw StateError('Node identity generator returned an invalid id.');
      }
      await _store.write(generated);
      return generated;
    } catch (_) {
      // Identity persistence improves continuity, but inability to persist must
      // never prevent the app/session from starting. Fall back to an ephemeral
      // id for this process and try persistence again on the next launch.
      final fallback = _generator().toLowerCase();
      if (!isValid(fallback)) {
        throw StateError('Node identity fallback generator returned an invalid id.');
      }
      return fallback;
    }
  }

  static bool isValid(String? value) =>
      value != null && RegExp(r'^[0-9a-fA-F]{16}$').hasMatch(value);

  static String _newNodeId() {
    final random = Random.secure();
    final first = random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
    final second = random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
    return '$first$second';
  }
}
