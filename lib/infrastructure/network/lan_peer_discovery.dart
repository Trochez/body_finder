import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../application/geometry/relative_position_solver.dart';
import '../../application/session/coordinator_election.dart';
import '../../application/session/peer_registry.dart';
import '../../domain/geometry/range_observation.dart';

class PeerDiscoverySnapshot {
  const PeerDiscoverySnapshot({
    required this.localNodeId,
    required this.peers,
    required this.coordinatorId,
    required this.unresolvedNodeIds,
    required this.rangeObservationCount,
  });

  final String localNodeId;
  final List<PeerRecord> peers;
  final String? coordinatorId;
  final Set<String> unresolvedNodeIds;
  final int rangeObservationCount;

  int get nodeCount => peers.length;
  int get positionedNodeCount => peers.where((peer) => peer.position != null).length;
  bool get has2DFrame => positionedNodeCount >= 3;
}

typedef PeerDiscoveryListener = void Function(PeerDiscoverySnapshot snapshot);

class LanPeerDiscovery {
  LanPeerDiscovery({
    PeerDiscoveryListener? onChanged,
    String? nodeId,
    String? platform,
  })  : onChanged = onChanged,
        nodeId = nodeId ?? _newNodeId(),
        platform = platform ?? Platform.operatingSystem;

  static const int port = 45892;
  static const String protocol = 'body_finder_peer_v1';
  static const Duration announceEvery = Duration(seconds: 1);
  static const Duration peerTimeout = Duration(seconds: 4);
  static const Duration rangeTimeout = Duration(seconds: 6);

  final PeerDiscoveryListener? onChanged;
  final String nodeId;
  final String platform;
  final PeerRegistry _registry = PeerRegistry();
  final RelativePositionSolver _positionSolver = const RelativePositionSolver();
  final Map<String, RangeObservation> _localRanges = {};
  final Map<String, _ReceivedRange> _ranges = {};

  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _socketSubscription;
  Timer? _announceTimer;
  Timer? _expireTimer;

  bool get isRunning => _socket != null;

  PeerDiscoverySnapshot get snapshot {
    final activeIds = _registry.peers.map((peer) => peer.id).toSet();
    final solution = _positionSolver.solve(
      activeNodeIds: activeIds,
      observations: _ranges.values.map((stored) => stored.observation),
    );
    final peers = _registry.peers
        .map((peer) {
          final estimate = solution.positions[peer.id];
          return peer.withEstimatedPosition(
            estimate?.position,
            estimate?.sigmaMeters,
          );
        })
        .toList()
      ..sort((left, right) => left.id.compareTo(right.id));

    return PeerDiscoverySnapshot(
      localNodeId: nodeId,
      peers: peers,
      coordinatorId: electCoordinator(_registry.peers),
      unresolvedNodeIds: solution.unresolvedNodeIds,
      rangeObservationCount: solution.observationCount,
    );
  }

  Future<void> start() async {
    if (isRunning) return;

    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      port,
      reuseAddress: true,
    );
    socket.broadcastEnabled = true;
    _socket = socket;

    _socketSubscription = socket.listen(_handleSocketEvent);
    _refreshLocalRecord();
    _announce();

    _announceTimer = Timer.periodic(announceEvery, (_) => _announce());
    _expireTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _expireStaleState(),
    );
  }

  Future<void> stop() async {
    _announceTimer?.cancel();
    _expireTimer?.cancel();
    _announceTimer = null;
    _expireTimer = null;

    await _socketSubscription?.cancel();
    _socketSubscription = null;

    _socket?.close();
    _socket = null;
  }

  void publishLocalRange({
    required String peerNodeId,
    required double distanceMeters,
    required double sigmaMeters,
    required RangeSource source,
  }) {
    final observation = RangeObservation(
      fromNodeId: nodeId,
      toNodeId: peerNodeId,
      distanceMeters: distanceMeters,
      sigmaMeters: sigmaMeters,
      timestampMicros: _nowMicros(),
      source: source,
    );
    if (!observation.isValid) return;
    _localRanges[peerNodeId] = observation;
    _storeRange(observation);
    if (isRunning) _announce();
    _emit();
  }

  void clearLocalRange(String peerNodeId) {
    _localRanges.remove(peerNodeId);
    _ranges.remove(_rangeStorageKey(nodeId, peerNodeId));
    if (isRunning) _announce();
    _emit();
  }

  void _handleSocketEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;

    Datagram? datagram;
    while ((datagram = _socket?.receive()) != null) {
      _handleDatagram(datagram!);
    }
  }

  void _handleDatagram(Datagram datagram) {
    try {
      final decoded = jsonDecode(utf8.decode(datagram.data));
      if (decoded is! Map<String, dynamic>) return;
      if (decoded['protocol'] != protocol) return;

      final remoteNodeId = decoded['nodeId'];
      if (remoteNodeId is! String || remoteNodeId.isEmpty) return;
      if (remoteNodeId == nodeId) return;

      final remotePlatform = decoded['platform'];
      _registry.seen(
        remoteNodeId,
        _nowMicros(),
        platform: remotePlatform is String ? remotePlatform : null,
      );

      final rawRanges = decoded['ranges'];
      if (rawRanges is List) {
        for (final rawRange in rawRanges) {
          final observation = _decodeRange(remoteNodeId, rawRange);
          if (observation != null) _storeRange(observation);
        }
      }
      _emit();
    } on FormatException {
      // Ignore unrelated LAN traffic on the discovery port.
    }
  }

  void _announce() {
    final socket = _socket;
    if (socket == null) return;

    _refreshLocalRecord();
    final now = _nowMicros();
    final refreshedLocalRanges = <RangeObservation>[];
    for (final entry in _localRanges.entries) {
      final refreshed = RangeObservation(
        fromNodeId: nodeId,
        toNodeId: entry.key,
        distanceMeters: entry.value.distanceMeters,
        sigmaMeters: entry.value.sigmaMeters,
        timestampMicros: now,
        source: entry.value.source,
      );
      refreshedLocalRanges.add(refreshed);
      _localRanges[entry.key] = refreshed;
      _storeRange(refreshed);
    }

    final payload = utf8.encode(jsonEncode({
      'protocol': protocol,
      'nodeId': nodeId,
      'platform': platform,
      'timestampMicros': now,
      'ranges': refreshedLocalRanges
          .map((range) => {
                'toNodeId': range.toNodeId,
                'distanceMeters': range.distanceMeters,
                'sigmaMeters': range.sigmaMeters,
                'source': range.source.name,
              })
          .toList(growable: false),
    }));

    socket.send(
      payload,
      InternetAddress('255.255.255.255'),
      port,
    );
    _emit();
  }

  void _refreshLocalRecord() {
    _registry.seen(
      nodeId,
      _nowMicros(),
      platform: platform,
    );
  }

  void _expireStaleState() {
    final now = _nowMicros();
    final expired = _registry.expireBefore(now - peerTimeout.inMicroseconds);
    final activeIds = _registry.peers.map((peer) => peer.id).toSet()..add(nodeId);
    final staleKeys = _ranges.entries
        .where((entry) =>
            entry.value.receivedAtMicros < now - rangeTimeout.inMicroseconds ||
            !activeIds.contains(entry.value.observation.fromNodeId) ||
            !activeIds.contains(entry.value.observation.toNodeId))
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final key in staleKeys) {
      _ranges.remove(key);
    }
    for (final peerId in expired) {
      _localRanges.remove(peerId);
    }
    _refreshLocalRecord();
    if (expired.isNotEmpty || staleKeys.isNotEmpty) _emit();
  }

  void _storeRange(RangeObservation observation) {
    final normalized = RangeObservation(
      fromNodeId: observation.fromNodeId,
      toNodeId: observation.toNodeId,
      distanceMeters: observation.distanceMeters,
      sigmaMeters: observation.sigmaMeters,
      timestampMicros: _nowMicros(),
      source: observation.source,
    );
    _ranges[_rangeStorageKey(normalized.fromNodeId, normalized.toNodeId)] =
        _ReceivedRange(normalized, _nowMicros());
  }

  RangeObservation? _decodeRange(String remoteNodeId, Object? raw) {
    if (raw is! Map) return null;
    final toNodeId = raw['toNodeId'];
    final distance = raw['distanceMeters'];
    final sigma = raw['sigmaMeters'];
    final sourceName = raw['source'];
    if (toNodeId is! String || distance is! num || sigma is! num) return null;
    final source = RangeSource.values
        .where((value) => value.name == sourceName)
        .firstOrNull;
    if (source == null) return null;
    final observation = RangeObservation(
      fromNodeId: remoteNodeId,
      toNodeId: toNodeId,
      distanceMeters: distance.toDouble(),
      sigmaMeters: sigma.toDouble(),
      timestampMicros: _nowMicros(),
      source: source,
    );
    return observation.isValid ? observation : null;
  }

  static String _rangeStorageKey(String from, String to) => '$from->$to';

  void _emit() => onChanged?.call(snapshot);

  static int _nowMicros() => DateTime.now().microsecondsSinceEpoch;

  static String _newNodeId() {
    final random = Random.secure();
    final first = random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
    final second = random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
    return '$first$second';
  }
}

class _ReceivedRange {
  const _ReceivedRange(this.observation, this.receivedAtMicros);

  final RangeObservation observation;
  final int receivedAtMicros;
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
