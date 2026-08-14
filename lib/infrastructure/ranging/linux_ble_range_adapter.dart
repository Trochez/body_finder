import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../bluetooth/ble_peer_identity_registry.dart';

class LinuxBleRangeSample {
  const LinuxBleRangeSample({
    required this.peerNodeId,
    required this.distanceMeters,
    required this.sigmaMeters,
    required this.rssiDbm,
  });

  final String peerNodeId;
  final double distanceMeters;
  final double sigmaMeters;
  final double rssiDbm;
}

class LinuxBleRangeAdapter {
  LinuxBleRangeAdapter({BlePeerIdentityRegistry? identityRegistry})
      : _identityRegistry = identityRegistry ?? BlePeerIdentityRegistry.instance;

  static const serviceUuid = '93f3b61e-5e3c-4a73-9d10-8fbc5cf4de31';
  static const _pathLossExponent = 2.2;
  static const _fallbackTxPowerDbm = -59.0;
  static const _minEmitInterval = Duration(milliseconds: 500);
  static const _diagnosticInterval = Duration(seconds: 5);

  final BlePeerIdentityRegistry _identityRegistry;

  Process? _scanner;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  Timer? _diagnosticTimer;
  void Function(LinuxBleRangeSample sample)? _onRange;
  void Function(String status)? _onStatus;
  String? _localNodeId;

  final Map<String, double> _smoothedRssi = <String, double>{};
  final Map<String, DateTime> _lastEmit = <String, DateTime>{};
  final Map<String, double> _latestRssiByAddress = <String, double>{};
  final Map<String, String> _advertisedNodeIdByAddress = <String, String>{};
  final Set<String> _seenAddresses = <String>{};
  final Set<String> _bodyFinderAddresses = <String>{};
  String? _pendingServiceDataAddress;
  String? _lastStatus;

  bool get started => _scanner != null;

  Future<String> start({
    required String nodeId,
    required void Function(LinuxBleRangeSample sample) onRange,
    void Function(String status)? onStatus,
  }) async {
    await stop();
    _onRange = onRange;
    _onStatus = onStatus;
    _localNodeId = nodeId.toLowerCase();

    if (!Platform.isLinux) return _status('unsupported');
    if (!RegExp(r'^[0-9a-fA-F]{16}$').hasMatch(nodeId)) {
      return _status('invalidNodeId');
    }

    final which = await Process.run(
      'sh',
      <String>['-lc', 'command -v bluetoothctl'],
    );
    if (which.exitCode != 0 || which.stdout.toString().trim().isEmpty) {
      return _status('bluezUnavailable');
    }

    final show = await Process.run('bluetoothctl', const <String>['show']);
    final controller = '${show.stdout}\n${show.stderr}';
    if (show.exitCode != 0 || !controller.contains('Controller ')) {
      return _status('noBluetoothController');
    }
    if (!RegExp(r'Powered:\s+yes', caseSensitive: false)
        .hasMatch(controller)) {
      return _status('bluetoothOff');
    }

    try {
      final process =
          await Process.start('bluetoothctl', const <String>['--monitor']);
      _scanner = process;
      _stdoutSub = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_handleScanLine);
      _stderrSub = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        final clean = stripAnsi(line);
        if (clean.toLowerCase().contains('failed')) {
          _status('scanWarning');
        }
      });

      // Scan all LE advertisements. The service UUID identifies a Body Finder
      // endpoint, but its human-readable ServiceData bytes are no longer used
      // as the authoritative logical identity on Linux. The BLE session
      // transport binds address -> persistent nodeId after receiving a valid
      // Body Finder session payload.
      process.stdin.writeln('menu scan');
      process.stdin.writeln('transport le');
      process.stdin.writeln('duplicate-data on');
      process.stdin.writeln('back');
      process.stdin.writeln('scan on');
      await process.stdin.flush();

      _diagnosticTimer = Timer.periodic(
        _diagnosticInterval,
        (_) => _emitDiagnosticStatus(),
      );
      return _status('started');
    } on ProcessException {
      await stop();
      return _status('bluezUnavailable');
    }
  }

  Future<void> stop() async {
    _diagnosticTimer?.cancel();
    _diagnosticTimer = null;

    final process = _scanner;
    _scanner = null;
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
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;
    _smoothedRssi.clear();
    _lastEmit.clear();
    _latestRssiByAddress.clear();
    _advertisedNodeIdByAddress.clear();
    _seenAddresses.clear();
    _bodyFinderAddresses.clear();
    _pendingServiceDataAddress = null;
    _onRange = null;
    _onStatus = null;
    _localNodeId = null;
    _lastStatus = null;
  }

  void _handleScanLine(String line) {
    final clean = stripAnsi(line);

    // BlueZ prints the service-data header and byte payload on separate lines.
    // The payload is kept as a discovery diagnostic only; its exact text
    // representation is not trusted as the persistent session identity.
    final pendingAddress = _pendingServiceDataAddress;
    if (pendingAddress != null && !clean.contains('Device ')) {
      final advertisedNodeId = parseNodeIdFromServiceDataBytes(clean);
      if (advertisedNodeId != null) {
        _pendingServiceDataAddress = null;
        _advertisedNodeIdByAddress[pendingAddress] = advertisedNodeId;
        final rssi = _latestRssiByAddress[pendingAddress];
        if (rssi != null) _emitRangeIfIdentityBound(pendingAddress, rssi);
        return;
      }
    }

    final addressMatch = RegExp(
      r'Device\s+([0-9A-Fa-f:]{17})',
    ).firstMatch(clean);
    if (addressMatch == null) return;

    final address = addressMatch.group(1)!.toUpperCase();
    _seenAddresses.add(address);

    final lower = clean.toLowerCase();
    if (lower.contains('servicedata.${serviceUuid.toLowerCase()}')) {
      _bodyFinderAddresses.add(address);
      _pendingServiceDataAddress = address;
      _status('peerMatchedAwaitingSessionIdentity');
      return;
    }

    final rssi = parseRssiFromScanLine(clean);
    if (rssi == null || !rssi.isFinite) return;
    _latestRssiByAddress[address] = rssi;
    if (_bodyFinderAddresses.contains(address)) {
      _emitRangeIfIdentityBound(address, rssi);
    }
  }

  void _emitRangeIfIdentityBound(String address, double rawRssi) {
    final peerNodeId = _identityRegistry.nodeIdForSource(address);
    if (peerNodeId == null) {
      _status('peerMatchedAwaitingSessionIdentity');
      return;
    }
    if (peerNodeId == _localNodeId) return;
    _emitRange(address, peerNodeId, rawRssi);
  }

  void _emitRange(String address, String peerNodeId, double rawRssi) {
    final previous = _smoothedRssi[peerNodeId];
    final filteredRssi = previous == null
        ? rawRssi
        : previous * 0.72 + rawRssi * 0.28;
    _smoothedRssi[peerNodeId] = filteredRssi;

    final distance = estimateDistanceMeters(filteredRssi);
    final sigma = math.max(1.0, distance * 0.75);
    final now = DateTime.now();
    final last = _lastEmit[peerNodeId];
    if (last != null && now.difference(last) < _minEmitInterval) return;
    _lastEmit[peerNodeId] = now;
    _latestRssiByAddress[address] = rawRssi;

    _status('ranging');
    _onRange?.call(
      LinuxBleRangeSample(
        peerNodeId: peerNodeId,
        distanceMeters: distance,
        sigmaMeters: sigma,
        rssiDbm: filteredRssi,
      ),
    );
  }

  void _emitDiagnosticStatus() {
    if (_scanner == null) return;
    if (_bodyFinderAddresses.any(
      (address) => _identityRegistry.nodeIdForSource(address) != null,
    )) {
      return;
    }
    if (_bodyFinderAddresses.isNotEmpty) {
      _status('peerMatchedAwaitingSessionIdentity');
    } else if (_seenAddresses.isEmpty) {
      _status('scanningNoAdvertisements');
    } else {
      _status('scanningNoBodyFinderPeers');
    }
  }

  String _status(String value) {
    if (_lastStatus == value) return value;
    _lastStatus = value;
    _onStatus?.call(value);
    return value;
  }

  static double estimateDistanceMeters(double rssiDbm) {
    final value = math.pow(
      10.0,
      (_fallbackTxPowerDbm - rssiDbm) / (10.0 * _pathLossExponent),
    ).toDouble();
    return value.clamp(0.10, 50.0).toDouble();
  }

  /// Parses both common BlueZ RSSI forms:
  /// `RSSI: -79` and `RSSI: 0xffffffb1 (-79)`.
  static double? parseRssiFromScanLine(String text) {
    final clean = stripAnsi(text);
    final parenthesized = RegExp(r'RSSI:.*\((-?\d+)\)')
        .firstMatch(clean)
        ?.group(1);
    if (parenthesized != null) return double.tryParse(parenthesized);

    final direct = RegExp(r'RSSI:\s*(-?\d+)(?:\s|$)')
        .firstMatch(clean)
        ?.group(1);
    return direct == null ? null : double.tryParse(direct);
  }

  /// Parses Body Finder ServiceData only as a diagnostic hint. Linux session
  /// and ranging identity no longer depends on this value; the authoritative
  /// mapping is learned from a valid reassembled Body Finder session payload.
  static String? parseNodeIdFromServiceDataBytes(String text) {
    final clean = stripAnsi(text).toLowerCase().replaceAll('0x', ' ');
    var bytes = RegExp(r'\b([0-9a-f]{2})\b')
        .allMatches(clean)
        .map((match) => match.group(1)!)
        .toList(growable: false);
    if (bytes.length >= 10 && bytes.first == '10') {
      bytes = bytes.skip(1).toList(growable: false);
    }
    if (bytes.length < 8) return null;
    return bytes.take(8).join();
  }

  static String? parseNodeIdFromInfo(String text) {
    final clean = stripAnsi(text).toLowerCase();
    final uuidIndex = clean.indexOf(serviceUuid);
    if (uuidIndex < 0) return null;

    final tail = clean.substring(uuidIndex + serviceUuid.length);
    final direct = RegExp(r'\b(?:0x)?([0-9a-f]{16})\b').firstMatch(tail);
    if (direct != null) return direct.group(1);

    return parseNodeIdFromServiceDataBytes(tail);
  }

  static String stripAnsi(String value) => value.replaceAll(
        RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'),
        '',
      );
}
