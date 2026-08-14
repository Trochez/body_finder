import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dbus/dbus.dart';

import '../bluetooth/ble_peer_identity_registry.dart';
import '../ranging/linux_ble_range_adapter.dart';
import 'ble_session_transport.dart';

/// Linux BLE session/control client that discovers Body Finder by service UUID
/// and connects by BLE address before trusting any advertised node identity.
///
/// This adapter is communication-only. A BLE address is a temporary transport
/// source key; the persistent Body Finder node ID is learned from a valid,
/// reassembled `body_finder_peer_v1` payload by [BleSessionTransport].
class LinuxAddressFirstBleSessionPlatformAdapter
    implements BleSessionPlatformAdapter, BleSessionPeerIdentityBinder {
  LinuxAddressFirstBleSessionPlatformAdapter({
    BlePeerIdentityRegistry? identityRegistry,
  }) : _identityRegistry = identityRegistry ?? BlePeerIdentityRegistry.instance;

  static const serviceUuid = '93f3b61e-5e3c-4a73-9d10-8fbc5cf4de31';
  static const characteristicUuid = '93f3b61f-5e3c-4a73-9d10-8fbc5cf4de31';
  static const _bluezName = 'org.bluez';
  static const _adapterInterface = 'org.bluez.Adapter1';
  static const _deviceInterface = 'org.bluez.Device1';
  static const _characteristicInterface = 'org.bluez.GattCharacteristic1';
  static const _connectRetry = Duration(seconds: 2);
  static const _addressBootstrapRetry = Duration(seconds: 4);

  final BlePeerIdentityRegistry _identityRegistry;

  DBusClient? _client;
  DBusRemoteObjectManager? _manager;
  DBusRemoteObject? _adapter;
  DBusObjectPath? _adapterPath;
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

  final Set<String> _bodyFinderAddresses = <String>{};
  final Set<String> _boundIdentitySources = <String>{};
  final Map<String, DateTime> _bootstrapAttemptAt = <String, DateTime>{};
  final Map<String, _AddressFirstPeerSession> _peers =
      <String, _AddressFirstPeerSession>{};

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
    if (!RegExp(r'^[0-9a-fA-F]{16}$').hasMatch(nodeId)) {
      return 'invalidNodeId';
    }

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
      final adapters = objects.entries.where(
        (entry) => entry.value.containsKey(_adapterInterface),
      );
      if (adapters.isEmpty) {
        await client.close();
        _clearCallbacks();
        return 'noBluetoothController';
      }

      final selected = adapters.first;
      final powered = _property(selected.value[_adapterInterface], 'Powered');
      if (powered == null || !_boolProperty(powered)) {
        await client.close();
        _clearCallbacks();
        return 'bluetoothOff';
      }

      final adapter = DBusRemoteObject(
        client,
        name: _bluezName,
        path: selected.key,
      );
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
        // Older BlueZ releases still support unfiltered StartDiscovery.
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
      _adapterPath = selected.key;
      _running = true;

      await _startLiveDiscoveryMonitor();
      _pollTimer = Timer.periodic(
        const Duration(milliseconds: 650),
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
  void bindPeerIdentity({required String sourceKey, required String nodeId}) {
    final normalizedSource = sourceKey.toUpperCase();
    final normalizedNodeId = nodeId.toLowerCase();
    if (!RegExp(r'^[0-9a-f]{16}$').hasMatch(normalizedNodeId)) return;
    if (normalizedNodeId == _localNodeId) return;

    _identityRegistry.bind(
      sourceKey: normalizedSource,
      nodeId: normalizedNodeId,
    );
    _boundIdentitySources.add(normalizedSource);
    for (final peer in _peers.values) {
      if (peer.sourceKey == normalizedSource) {
        peer.boundNodeId = normalizedNodeId;
      }
    }
    _status('peerIdentityBoundFromSession');
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
              'type': const DBusString('request'),
            }),
          ],
          replySignature: DBusSignature(''),
        );
      } on DBusMethodResponseException catch (error) {
        peer.lastError = error.errorName;
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

    for (final source in _boundIdentitySources) {
      _identityRegistry.unbindSource(source);
    }
    _boundIdentitySources.clear();
    _bodyFinderAddresses.clear();
    _bootstrapAttemptAt.clear();

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
        // Discovery may already have ended.
      }
    }
    _adapter = null;
    _adapterPath = null;
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
    final match = RegExp(r'Device\s+([0-9A-Fa-f:]{17})').firstMatch(clean);
    if (match == null) return;
    if (!clean
        .toLowerCase()
        .contains('servicedata.${serviceUuid.toLowerCase()}')) {
      return;
    }

    final address = match.group(1)!.toUpperCase();
    if (_bodyFinderAddresses.add(address)) {
      _status('peerAdvertisementAddressMatched');
    }
    unawaited(_bootstrapAddressIfNeeded(address));
    unawaited(_refreshPeers());
  }

  Future<void> _refreshPeers() async {
    if (!_running || _polling) return;
    final manager = _manager;
    final client = _client;
    if (manager == null || client == null) return;
    _polling = true;
    try {
      final objects = await manager.getManagedObjects();
      final objectAddresses = <String>{};

      for (final entry in objects.entries) {
        final properties = entry.value[_deviceInterface];
        if (properties == null) continue;
        final address = _stringProperty(properties['Address'])?.toUpperCase();
        if (address == null) continue;

        final typedServiceDataMatch = _hasBodyFinderServiceData(
          properties['ServiceData'],
        );
        if (typedServiceDataMatch) _bodyFinderAddresses.add(address);
        if (!_bodyFinderAddresses.contains(address)) continue;
        objectAddresses.add(address);

        final sourceKey = address;
        final devicePath = entry.key.value;
        final peer = _peers.putIfAbsent(
          devicePath,
          () => _AddressFirstPeerSession(
            devicePath: entry.key,
            sourceKey: sourceKey,
          ),
        );
        peer.sourceKey = sourceKey;
        peer.address = address;
        peer.boundNodeId = _identityRegistry.nodeIdForSource(sourceKey);
        peer.connected = _boolProperty(properties['Connected']);
        peer.servicesResolved = _boolProperty(properties['ServicesResolved']);

        if (!peer.connected) {
          if (peer.characteristic != null) await _disposePeer(peer);
          if (_connectDue(peer)) await _connectPeer(peer);
        } else if (!peer.servicesResolved && peer.characteristic == null) {
          _status('peerConnectedResolvingServices');
        }
      }

      // A live ServiceData report can arrive before ObjectManager publishes the
      // corresponding Device1 object. Bootstrap a direct LE connection by
      // address and continue polling until the canonical Device1 appears.
      for (final address in _bodyFinderAddresses) {
        if (!objectAddresses.contains(address)) {
          unawaited(_bootstrapAddressIfNeeded(address));
        }
      }

      for (final peer in _peers.values) {
        if (peer.characteristic != null) continue;
        final characteristicEntry = objects.entries.where((entry) {
          if (!entry.key.value.startsWith('${peer.devicePath.value}/')) {
            return false;
          }
          final properties = entry.value[_characteristicInterface];
          if (properties == null) return false;
          final uuid = _stringProperty(properties['UUID']);
          return uuid?.toLowerCase() == characteristicUuid;
        });
        if (characteristicEntry.isNotEmpty) {
          await _bindCharacteristic(peer, characteristicEntry.first.key);
        } else if (peer.connected && peer.servicesResolved) {
          _status('peerCharacteristicMissing');
        }
      }
    } on DBusMethodResponseException catch (error) {
      _status(_refreshErrorStatus(error.errorName));
    } finally {
      _polling = false;
    }
  }

  bool _connectDue(_AddressFirstPeerSession peer) {
    if (peer.connecting) return false;
    final last = peer.lastConnectAttempt;
    return last == null || DateTime.now().difference(last) >= _connectRetry;
  }

  Future<void> _connectPeer(_AddressFirstPeerSession peer) async {
    final client = _client;
    if (client == null) return;
    peer.connecting = true;
    peer.lastConnectAttempt = DateTime.now();
    peer.lastError = null;
    _status('peerConnectingByAddress');

    final device = DBusRemoteObject(
      client,
      name: _bluezName,
      path: peer.devicePath,
    );
    peer.device = device;
    try {
      try {
        await device.setProperty(
          _deviceInterface,
          'PreferredBearer',
          const DBusString('le'),
        );
      } on DBusMethodResponseException {
        // Optional on some BlueZ builds; discovery was already LE-only.
      }

      await device.callMethod(
        _deviceInterface,
        'Connect',
        const <DBusValue>[],
        replySignature: DBusSignature(''),
      );
      peer.lastError = null;
      _status('peerConnected');
    } on DBusMethodResponseException catch (error) {
      peer.lastError = error.errorName;
      _status(_connectErrorStatus(error.errorName));
      if (_shouldBootstrapAfterConnectError(error.errorName)) {
        unawaited(_bootstrapAddressIfNeeded(peer.sourceKey, force: true));
      }
    } finally {
      peer.connecting = false;
    }
  }

  Future<void> _bootstrapAddressIfNeeded(
    String address, {
    bool force = false,
  }) async {
    if (!_running) return;
    final now = DateTime.now();
    final last = _bootstrapAttemptAt[address];
    if (!force &&
        last != null &&
        now.difference(last) < _addressBootstrapRetry) {
      return;
    }
    _bootstrapAttemptAt[address] = now;

    final adapter = _adapter;
    if (adapter != null) {
      for (final addressType in const <String>['random', 'public']) {
        try {
          await adapter.callMethod(
            _adapterInterface,
            'ConnectDevice',
            <DBusValue>[
              DBusDict.stringVariant(<String, DBusValue>{
                'Address': DBusString(address),
                'AddressType': DBusString(addressType),
              }),
            ],
            replySignature: DBusSignature('o'),
          );
          _status('peerAddressConnectRequested');
          unawaited(_refreshPeers());
          return;
        } on DBusMethodResponseException catch (error) {
          if (error.errorName.endsWith('.AlreadyExists')) {
            _status('peerAddressDeviceReady');
            unawaited(_refreshPeers());
            return;
          }
          if (error.errorName.endsWith('.NotSupported') ||
              error.errorName.endsWith('.UnknownMethod')) {
            break;
          }
          // A random/public mismatch may fail before a physical connection is
          // attempted, so try the alternate LE address type once.
        }
      }
    }

    // Compatibility fallback for BlueZ builds where Adapter1.ConnectDevice is
    // disabled. bluetoothctl uses the same BlueZ daemon and the already-active
    // scan report, while GATT traffic remains on typed D-Bus once connected.
    final scanner = _liveScanner;
    if (scanner != null) {
      try {
        scanner.stdin.writeln('connect $address');
        await scanner.stdin.flush();
        _status('peerAddressConnectCliFallback');
      } catch (_) {
        _status('peerAddressConnectBootstrapFailed');
      }
    }
  }

  Future<void> _bindCharacteristic(
    _AddressFirstPeerSession peer,
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
    final subscription = characteristic.propertiesChanged.listen((signal) {
      if (signal.interface != _characteristicInterface) return;
      final value = signal.changedProperties['Value'];
      final bytes = _byteArray(value);
      if (bytes == null || bytes.isEmpty) return;
      _onChunk?.call(
        BleSessionChunk(
          sourceKey: peer.sourceKey,
          bytes: Uint8List.fromList(bytes),
        ),
      );
    });

    try {
      await characteristic.callMethod(
        _characteristicInterface,
        'StartNotify',
        const <DBusValue>[],
        replySignature: DBusSignature(''),
      );
      peer.characteristic = characteristic;
      peer.notificationSubscription = subscription;
      _status('peerSubscribed');
    } on DBusMethodResponseException catch (error) {
      await subscription.cancel();
      peer.lastError = error.errorName;
      _status('peerSubscribePending');
    }
  }

  Future<void> _disposePeer(_AddressFirstPeerSession peer) async {
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
    final subscribed = _peers.values.where(
      (peer) => peer.characteristic != null,
    );
    if (subscribed.isNotEmpty) {
      if (subscribed.any((peer) => peer.boundNodeId != null)) {
        _status('peerSubscribedIdentityBound');
      } else {
        _status('peerSubscribedAwaitingSessionIdentity');
      }
      return;
    }
    if (_bodyFinderAddresses.isEmpty) {
      _status('scanningForGattPeer');
      return;
    }
    if (_peers.isEmpty) {
      _status('peerAdvertisementAddressMatchedAwaitingBluezDevice');
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
    final error = _peers.values
        .map((peer) => peer.lastError)
        .whereType<String>()
        .firstOrNull;
    if (error != null) {
      _status(_connectErrorStatus(error));
      return;
    }
    _status('peerConnectPendingByAddress');
  }

  void _status(String status) => _onStatus?.call(status);

  void _clearCallbacks() {
    _onChunk = null;
    _onStatus = null;
  }

  static bool _shouldBootstrapAfterConnectError(String errorName) =>
      errorName.endsWith('.UnknownObject') ||
      errorName.endsWith('.NotReady') ||
      errorName.endsWith('.Failed');

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
    if (errorName.endsWith('.UnknownObject')) {
      return 'peerConnectAwaitingBluezDevice';
    }
    if (errorName.endsWith('.Failed')) return 'peerConnectFailed';
    return 'peerConnectError';
  }

  static String _refreshErrorStatus(String errorName) =>
      errorName.endsWith('.UnknownObject')
          ? 'bluezRefreshAwaitingDevice'
          : 'bluezRefreshFailed';

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

  static bool _hasBodyFinderServiceData(DBusValue? serviceDataValue) {
    if (serviceDataValue == null) return false;
    final serviceData = _unwrap(serviceDataValue);
    if (serviceData.signature != DBusSignature('a{sv}')) return false;
    return serviceData
        .asStringVariantDict()
        .keys
        .any((key) => key.toLowerCase() == serviceUuid);
  }
}

class _AddressFirstPeerSession {
  _AddressFirstPeerSession({
    required this.devicePath,
    required this.sourceKey,
  });

  final DBusObjectPath devicePath;
  String sourceKey;
  String? address;
  String? boundNodeId;
  DBusRemoteObject? device;
  DBusRemoteObject? characteristic;
  StreamSubscription<DBusPropertiesChangedSignal>? notificationSubscription;
  bool connecting = false;
  bool connected = false;
  bool servicesResolved = false;
  DateTime? lastConnectAttempt;
  String? lastError;
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
