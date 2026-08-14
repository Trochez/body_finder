import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dbus/dbus.dart';

import '../ranging/linux_ble_range_adapter.dart';
import 'ble_session_transport.dart';

/// Native Linux BLE session client using BlueZ's public D-Bus interfaces.
///
/// It discovers Body Finder advertisements, connects to their GATT service,
/// subscribes to the session characteristic and writes framed chunks back.
/// The adapter is communication-only and never creates physical range data.
///
/// Physical validation showed that BlueZ's live bluetoothctl event stream
/// reliably exposes Body Finder ServiceData even when the same data is not
/// consistently present in ObjectManager snapshots. The control client now
/// uses that proven live advertisement stream to map node IDs to BLE device
/// addresses, while all connection/GATT traffic still uses BlueZ D-Bus.
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
  Timer? _diagnosticTimer;
  bool _polling = false;
  bool _running = false;
  String? _localNodeId;
  BleSessionChunkHandler? _onChunk;
  BleSessionPlatformStatusHandler? _onStatus;

  Process? _liveScanner;
  StreamSubscription<String>? _liveStdoutSub;
  StreamSubscription<String>? _liveStderrSub;
  String? _pendingServiceDataAddress;
  final Map<String, String> _livePeerNodeIdByAddress = <String, String>{};

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
      // physical validation confirmed compact ServiceData advertisements are
      // not exposed consistently by every BlueZ discovery API.
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

      // Use the same live BlueZ advertisement representation that has already
      // been validated by the Linux BLE RSSI adapter on physical hardware.
      // This feed only discovers nodeId <-> address mappings; D-Bus remains the
      // authoritative connection/GATT API.
      await _startLiveDiscoveryMonitor();

      _pollTimer = Timer.periodic(
        const Duration(milliseconds: 700),
        (_) => unawaited(_refreshPeers()),
      );
      _diagnosticTimer = Timer.periodic(
        const Duration(seconds: 4),
        (_) => _emitConnectionDiagnostic(),
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
        // Session/control traffic must be reliable. BlueZ "request" maps to
        // ATT Write Request (with response), so awaiting WriteValue provides
        // per-chunk flow control and prevents bursts being dropped.
        await characteristic.callMethod(
          _characteristicInterface,
          'WriteValue',
          <DBusValue>[
            DBusArray.byte(chunk),
            DBusDict.stringVariant(<String, DBusValue>{
              'type': const DBusString('request'),
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
    _diagnosticTimer?.cancel();
    _diagnosticTimer = null;

    await _stopLiveDiscoveryMonitor();

    for (final peer in _peers.values.toList(growable: false)) {
      await _disposePeer(peer);
    }
    _peers.clear();
    _livePeerNodeIdByAddress.clear();
    _pendingServiceDataAddress = null;

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

  Future<void> _startLiveDiscoveryMonitor() async {
    try {
      final process = await Process.start(
        'bluetoothctl',
        const <String>['--monitor'],
      );
      _liveScanner = process;
      _liveStdoutSub = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_handleLiveScanLine);
      _liveStderrSub = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        final clean = LinuxBleRangeAdapter.stripAnsi(line).toLowerCase();
        if (clean.contains('failed')) _status('liveDiscoveryWarning');
      });

      process.stdin.writeln('menu scan');
      process.stdin.writeln('transport le');
      process.stdin.writeln('duplicate-data on');
      process.stdin.writeln('back');
      process.stdin.writeln('scan on');
      await process.stdin.flush();
      _status('scanningForGattPeer');
    } on ProcessException {
      // D-Bus discovery still remains active. Keep the transport alive and
      // report that the physically validated live discovery fallback is absent.
      _status('liveDiscoveryUnavailable');
    }
  }

  Future<void> _stopLiveDiscoveryMonitor() async {
    final process = _liveScanner;
    _liveScanner = null;
    if (process != null) {
      try {
        process.stdin.writeln('scan off');
        process.stdin.writeln('quit');
        await process.stdin.flush();
      } catch (_) {
        // Best effort during teardown.
      }
      process.kill();
    }
    await _liveStdoutSub?.cancel();
    await _liveStderrSub?.cancel();
    _liveStdoutSub = null;
    _liveStderrSub = null;
  }

  void _handleLiveScanLine(String line) {
    final clean = LinuxBleRangeAdapter.stripAnsi(line);
    final pendingAddress = _pendingServiceDataAddress;
    if (pendingAddress != null && !clean.contains('Device ')) {
      final nodeId = LinuxBleRangeAdapter.parseNodeIdFromServiceDataBytes(clean);
      if (nodeId != null) {
        _pendingServiceDataAddress = null;
        if (nodeId != _localNodeId) {
          _livePeerNodeIdByAddress[pendingAddress] = nodeId;
          _status('peerAdvertisementMatched');
          unawaited(_refreshPeers());
        }
        return;
      }
    }

    final addressMatch = RegExp(
      r'Device\s+([0-9A-Fa-f:]{17})',
    ).firstMatch(clean);
    if (addressMatch == null) return;
    final address = addressMatch.group(1)!.toUpperCase();
    if (clean.toLowerCase().contains('servicedata.${serviceUuid.toLowerCase()}')) {
      _pendingServiceDataAddress = address;
    }
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

        final address = _stringProperty(deviceProperties['Address'])?.toUpperCase();
        final dbusNodeId = _nodeIdFromServiceData(deviceProperties['ServiceData']);
        final liveNodeId = address == null ? null : _livePeerNodeIdByAddress[address];
        final peerNodeId = dbusNodeId ?? liveNodeId;
        if (peerNodeId == null || peerNodeId == _localNodeId) continue;

        // The Android advertisement now carries an optional freshness byte.
        // When BlueZ exposes ServiceData through Device1, that typed D-Bus
        // value is authoritative and should correct any stale/shifted identity
        // previously inferred from bluetoothctl's human-readable monitor text.
        if (address != null && dbusNodeId != null) {
          if (liveNodeId != null && liveNodeId != dbusNodeId) {
            _status('peerIdentityCorrectedFromDbus');
          }
          _livePeerNodeIdByAddress[address] = dbusNodeId;
        }

        final devicePath = entry.key.value;
        final session = _peers.putIfAbsent(
          devicePath,
          () => _BluezPeerSession(
            devicePath: entry.key,
            peerNodeId: peerNodeId,
          ),
        );
        session.peerNodeId = peerNodeId;
        session.address = address;

        final connected = _boolProperty(deviceProperties['Connected']);
        final servicesResolved = _boolProperty(deviceProperties['ServicesResolved']);
        session.connected = connected;
        session.servicesResolved = servicesResolved;

        if (!connected) {
          // Any cached GATT object belongs to the previous connection and must
          // not prevent service re-binding after a reconnect.
          if (session.characteristic != null) {
            await _disposePeer(session);
          }
          if (!session.connecting) {
            await _connectPeer(session);
          }
        } else if (!servicesResolved && session.characteristic == null) {
          _status('peerConnectedResolvingServices');
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
        } else if (session.connected && session.servicesResolved) {
          _status('peerCharacteristicMissing');
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
    peer.lastConnectError = null;
    _status('peerConnecting');
    final device = DBusRemoteObject(
      client,
      name: _bluezName,
      path: peer.devicePath,
    );
    peer.device = device;
    try {
      // Android is advertising a BLE GATT endpoint. On dual-mode peers BlueZ
      // may otherwise choose BR/EDR when bearer timestamps are ambiguous.
      // PreferredBearer is optional/experimental on some BlueZ releases, so a
      // failure to set it must never block the ordinary Device1.Connect path.
      try {
        await device.setProperty(
          _deviceInterface,
          'PreferredBearer',
          const DBusString('le'),
        );
      } on DBusMethodResponseException {
        // Unsupported on older/non-experimental BlueZ; Connect still works.
      }

      await device.callMethod(
        _deviceInterface,
        'Connect',
        const <DBusValue>[],
        replySignature: DBusSignature(''),
      );
      peer.lastConnectError = null;
      _status('peerConnected');
    } on DBusMethodResponseException catch (error) {
      peer.lastConnectError = error.errorName;
      _status(_connectErrorStatus(error.errorName));
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
    _status('peerSubscribing');
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
        // Best effort during teardown or after a remote disconnect.
      }
    }
    peer.characteristic = null;
  }

  void _emitConnectionDiagnostic() {
    if (!_running) return;
    if (_peers.values.any((peer) => peer.characteristic != null)) {
      _status('peerSubscribed');
      return;
    }
    if (_livePeerNodeIdByAddress.isEmpty) {
      _status('scanningForGattPeer');
      return;
    }
    if (_peers.isEmpty) {
      _status('peerAdvertisementMatchedAwaitingBluezDevice');
      return;
    }
    if (_peers.values.any((peer) => peer.connected && !peer.servicesResolved)) {
      _status('peerConnectedResolvingServices');
      return;
    }
    if (_peers.values.any((peer) => peer.connected && peer.servicesResolved)) {
      _status('peerCharacteristicMissing');
      return;
    }
    final connectError = _peers.values
        .map((peer) => peer.lastConnectError)
        .whereType<String>()
        .firstOrNull;
    if (connectError != null) {
      _status(_connectErrorStatus(connectError));
      return;
    }
    _status('peerConnectPending');
  }

  void _status(String status) => _onStatus?.call(status);

  void _clearCallbacks() {
    _onChunk = null;
    _onStatus = null;
  }

  static String _connectErrorStatus(String errorName) {
    if (errorName.endsWith('.InProgress')) return 'peerConnectInProgress';
    if (errorName.endsWith('.AlreadyConnected')) return 'peerConnected';
    if (errorName.endsWith('.NotReady')) return 'peerConnectNotReady';
    if (errorName.endsWith('.BREDR.ProfileUnavailable')) {
      return 'peerConnectBredrProfileUnavailable';
    }
    if (errorName.endsWith('.AuthenticationFailed')) {
      return 'peerConnectAuthenticationFailed';
    }
    if (errorName.endsWith('.AuthenticationRejected')) {
      return 'peerConnectAuthenticationRejected';
    }
    if (errorName.endsWith('.ConnectionAttemptFailed')) {
      return 'peerConnectAttemptFailed';
    }
    if (errorName.endsWith('.Failed')) return 'peerConnectFailed';
    return 'peerConnectError';
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
    if (bytes == null || bytes.length < 8) return null;
    return bytes
        .take(8)
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }
}

class _BluezPeerSession {
  _BluezPeerSession({
    required this.devicePath,
    required this.peerNodeId,
  });

  final DBusObjectPath devicePath;
  String peerNodeId;
  String? address;
  DBusRemoteObject? device;
  DBusRemoteObject? characteristic;
  StreamSubscription<DBusPropertiesChangedSignal>? notificationSubscription;
  bool connecting = false;
  bool connected = false;
  bool servicesResolved = false;
  String? lastConnectError;
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
