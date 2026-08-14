import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dbus/dbus.dart';

import 'ble_session_transport.dart';

/// Native Linux BLE session client using BlueZ's public D-Bus interfaces.
///
/// It discovers Body Finder advertisements, connects to their GATT service,
/// subscribes to the session characteristic and writes framed chunks back.
/// The adapter is communication-only and never creates physical range data.
class LinuxBluezSessionPlatformAdapter implements BleSessionPlatformAdapter {
  static const serviceUuid = '93f3b61e-5e3c-4a73-9d10-8fbc5cf4de31';
  static const characteristicUuid = '93f3b61f-5e3c-4a73-9d10-8fbc5cf4de31';
  static const _bluezName = 'org.bluez';
  static const _adapterInterface = 'org.bluez.Adapter1';
  static const _deviceInterface = 'org.bluez.Device1';
  static const _characteristicInterface = 'org.bluez.GattCharacteristic1';

  DBusClient? _client;
  DBusRemoteObjectManager? _manager;
  DBusRemoteObject? _adapter;
  Timer? _pollTimer;
  bool _polling = false;
  bool _running = false;
  String? _localNodeId;
  BleSessionChunkHandler? _onChunk;
  BleSessionPlatformStatusHandler? _onStatus;

  final Map<String, _BluezPeerSession> _peers = <String, _BluezPeerSession>{};

  @override
  bool get isRunning => _running;

  @override
  Future<String> start({
    required String nodeId,
    required BleSessionChunkHandler onChunk,
    BleSessionPlatformStatusHandler? onStatus,
  }) async {
    await stop();
    if (!Platform.isLinux) return 'unsupported';
    if (!RegExp(r'^[0-9a-fA-F]{16}$').hasMatch(nodeId)) return 'invalidNodeId';

    _localNodeId = nodeId.toLowerCase();
    _onChunk = onChunk;
    _onStatus = onStatus;

    try {
      final client = DBusClient.system();
      final manager = DBusRemoteObjectManager(
        client,
        name: _bluezName,
        path: DBusObjectPath('/'),
      );
      final objects = await manager.getManagedObjects();
      final adapterEntry = objects.entries.where(
        (entry) => entry.value.containsKey(_adapterInterface),
      );
      if (adapterEntry.isEmpty) {
        await client.close();
        _clearCallbacks();
        return 'noBluetoothController';
      }

      final selected = adapterEntry.first;
      final powered = _property(selected.value[_adapterInterface], 'Powered');
      if (powered == null || !powered.asBoolean()) {
        await client.close();
        _clearCallbacks();
        return 'bluetoothOff';
      }

      final adapter = DBusRemoteObject(
        client,
        name: _bluezName,
        path: selected.key,
      );
      // Restrict discovery to LE, but do not filter by service UUID because
      // some BlueZ versions do not apply UUID filters consistently to compact
      // ServiceData advertisements (confirmed by the prior physical test).
      try {
        await adapter.callMethod(
          _adapterInterface,
          'SetDiscoveryFilter',
          <DBusValue>[
            DBusDict.stringVariant(<String, DBusValue>{
              'Transport': const DBusString('le'),
              'DuplicateData': const DBusBoolean(true),
            }),
          ],
          replySignature: DBusSignature(''),
        );
      } on DBusMethodResponseException {
        // Older BlueZ still supports unfiltered StartDiscovery.
      }
      await adapter.callMethod(
        _adapterInterface,
        'StartDiscovery',
        const <DBusValue>[],
        replySignature: DBusSignature(''),
      );

      _client = client;
      _manager = manager;
      _adapter = adapter;
      _running = true;
      _pollTimer = Timer.periodic(
        const Duration(milliseconds: 900),
        (_) => unawaited(_refreshPeers()),
      );
      unawaited(_refreshPeers());
      _status('started');
      return 'started';
    } on DBusMethodResponseException {
      await stop();
      return 'bluezUnavailable';
    } on Exception {
      await stop();
      return 'bluezUnavailable';
    }
  }

  @override
  Future<void> sendChunk(Uint8List chunk) async {
    if (!_running || chunk.isEmpty) return;
    final peers = _peers.values
        .where((peer) => peer.characteristic != null)
        .toList(growable: false);
    for (final peer in peers) {
      final characteristic = peer.characteristic;
      if (characteristic == null) continue;
      try {
        await characteristic.callMethod(
          _characteristicInterface,
          'WriteValue',
          <DBusValue>[
            DBusArray.byte(chunk),
            DBusDict.stringVariant(<String, DBusValue>{
              'type': const DBusString('command'),
            }),
          ],
          replySignature: DBusSignature(''),
        );
      } on DBusMethodResponseException {
        _status('peerWriteFailed');
      }
    }
  }

  @override
  Future<void> stop() async {
    _running = false;
    _pollTimer?.cancel();
    _pollTimer = null;

    for (final peer in _peers.values.toList(growable: false)) {
      await _disposePeer(peer);
    }
    _peers.clear();

    final adapter = _adapter;
    if (adapter != null) {
      try {
        await adapter.callMethod(
          _adapterInterface,
          'StopDiscovery',
          const <DBusValue>[],
          replySignature: DBusSignature(''),
        );
      } on DBusMethodResponseException {
        // Best effort; discovery may already have ended with the controller.
      }
    }
    _adapter = null;
    _manager = null;
    final client = _client;
    _client = null;
    if (client != null) await client.close();
    _localNodeId = null;
    _clearCallbacks();
  }

  Future<void> _refreshPeers() async {
    if (!_running || _polling) return;
    final manager = _manager;
    final client = _client;
    if (manager == null || client == null) return;
    _polling = true;
    try {
      final objects = await manager.getManagedObjects();
      for (final entry in objects.entries) {
        final deviceProperties = entry.value[_deviceInterface];
        if (deviceProperties == null) continue;
        final peerNodeId = _nodeIdFromServiceData(deviceProperties['ServiceData']);
        if (peerNodeId == null || peerNodeId == _localNodeId) continue;

        final devicePath = entry.key.value;
        final session = _peers.putIfAbsent(
          devicePath,
          () => _BluezPeerSession(
            devicePath: entry.key,
            peerNodeId: peerNodeId,
          ),
        );
        session.peerNodeId = peerNodeId;

        final connected = _boolProperty(deviceProperties['Connected']);
        if (!connected && !session.connecting) {
          await _connectPeer(session);
        }
      }

      // Service discovery adds GATT characteristic objects beneath connected
      // device paths. Bind any newly resolved Body Finder characteristic.
      for (final session in _peers.values) {
        if (session.characteristic != null) continue;
        final characteristicEntry = objects.entries.where((entry) {
          if (!entry.key.value.startsWith('${session.devicePath.value}/')) return false;
          final properties = entry.value[_characteristicInterface];
          if (properties == null) return false;
          final uuid = _stringProperty(properties['UUID']);
          return uuid?.toLowerCase() == characteristicUuid;
        });
        if (characteristicEntry.isNotEmpty) {
          await _bindCharacteristic(session, characteristicEntry.first.key);
        }
      }
    } on DBusMethodResponseException {
      _status('bluezRefreshFailed');
    } finally {
      _polling = false;
    }
  }

  Future<void> _connectPeer(_BluezPeerSession peer) async {
    final client = _client;
    if (client == null) return;
    peer.connecting = true;
    final device = DBusRemoteObject(
      client,
      name: _bluezName,
      path: peer.devicePath,
    );
    peer.device = device;
    try {
      await device.callMethod(
        _deviceInterface,
        'Connect',
        const <DBusValue>[],
        replySignature: DBusSignature(''),
      );
      _status('peerConnected');
    } on DBusMethodResponseException {
      // It may already be connected or still resolving services. Poll again.
      _status('peerConnectPending');
    } finally {
      peer.connecting = false;
    }
  }

  Future<void> _bindCharacteristic(
    _BluezPeerSession peer,
    DBusObjectPath characteristicPath,
  ) async {
    final client = _client;
    if (client == null) return;
    final characteristic = DBusRemoteObject(
      client,
      name: _bluezName,
      path: characteristicPath,
    );
    try {
      await characteristic.callMethod(
        _characteristicInterface,
        'StartNotify',
        const <DBusValue>[],
        replySignature: DBusSignature(''),
      );
      peer.characteristic = characteristic;
      peer.notificationSubscription = characteristic.propertiesChanged.listen(
        (signal) {
          if (signal.interface != _characteristicInterface) return;
          final value = signal.changedProperties['Value'];
          final bytes = _byteArray(value);
          if (bytes == null || bytes.isEmpty) return;
          _onChunk?.call(
            BleSessionChunk(
              sourceKey: peer.peerNodeId,
              bytes: Uint8List.fromList(bytes),
            ),
          );
        },
      );
      _status('peerSubscribed');
    } on DBusMethodResponseException {
      _status('peerSubscribePending');
    }
  }

  Future<void> _disposePeer(_BluezPeerSession peer) async {
    await peer.notificationSubscription?.cancel();
    peer.notificationSubscription = null;
    final characteristic = peer.characteristic;
    if (characteristic != null) {
      try {
        await characteristic.callMethod(
          _characteristicInterface,
          'StopNotify',
          const <DBusValue>[],
          replySignature: DBusSignature(''),
        );
      } on DBusMethodResponseException {
        // Best effort during teardown.
      }
    }
    peer.characteristic = null;
  }

  void _status(String status) => _onStatus?.call(status);

  void _clearCallbacks() {
    _onChunk = null;
    _onStatus = null;
  }

  static DBusValue? _property(Map<String, DBusValue>? properties, String name) =>
      properties == null ? null : properties[name];

  static DBusValue _unwrap(DBusValue value) =>
      value.signature == DBusSignature('v') ? value.asVariant() : value;

  static bool _boolProperty(DBusValue? value) {
    if (value == null) return false;
    final unwrapped = _unwrap(value);
    return unwrapped.signature == DBusSignature('b') && unwrapped.asBoolean();
  }

  static String? _stringProperty(DBusValue? value) {
    if (value == null) return null;
    final unwrapped = _unwrap(value);
    return unwrapped.signature == DBusSignature('s') ? unwrapped.asString() : null;
  }

  static List<int>? _byteArray(DBusValue? value) {
    if (value == null) return null;
    final unwrapped = _unwrap(value);
    if (unwrapped.signature != DBusSignature('ay')) return null;
    return unwrapped.asByteArray().toList(growable: false);
  }

  static String? _nodeIdFromServiceData(DBusValue? serviceDataValue) {
    if (serviceDataValue == null) return null;
    final serviceData = _unwrap(serviceDataValue);
    if (serviceData.signature != DBusSignature('a{sv}')) return null;
    final entries = serviceData.asStringVariantDict();
    final raw = entries.entries
        .where((entry) => entry.key.toLowerCase() == serviceUuid)
        .map((entry) => entry.value)
        .firstOrNull;
    final bytes = _byteArray(raw);
    if (bytes == null || bytes.length != 8) return null;
    return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }
}

class _BluezPeerSession {
  _BluezPeerSession({
    required this.devicePath,
    required this.peerNodeId,
  });

  final DBusObjectPath devicePath;
  String peerNodeId;
  DBusRemoteObject? device;
  DBusRemoteObject? characteristic;
  StreamSubscription<DBusPropertiesChangedSignal>? notificationSubscription;
  bool connecting = false;
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
