import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../../application/geometry/bootstrap_layout_solver.dart';
import '../../application/geometry/relative_position_solver.dart';
import '../../application/session/coordinator_election.dart';
import '../../application/session/peer_registry.dart';
import '../../domain/geometry/range_observation.dart';
import 'session_transport.dart';
import 'udp_lan_transport.dart';

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

  /// Nodes that still lack a defensible metric position.
  final Set<String> unresolvedNodeIds;
  final int rangeObservationCount;

  int get nodeCount => peers.length;

  /// Metric, range-derived positions only. Kept separate from the bootstrap
  /// topology layout so physical algorithms never consume synthetic meters.
  int get positionedNodeCount =>
      peers.where((peer) => peer.hasMetricPosition).length;

  int get bootstrapPositionedNodeCount =>
      peers.where((peer) => peer.hasBootstrapPosition).length;

  bool get has2DFrame => positionedNodeCount >= 3;
  bool get hasBootstrap2DLayout => bootstrapPositionedNodeCount >= 3;
}

typedef PeerDiscoveryListener = void Function(PeerDiscoverySnapshot snapshot);

/// Session membership, coordinator election and shared range-graph engine.
///
/// The historical class name is retained for source compatibility, but the
/// implementation is no longer coupled to LAN/UDP. Session messages can be
/// carried by any [SessionTransport]. LAN is only the default opportunistic
/// fast path.
class LanPeerDiscovery {
  LanPeerDiscovery({
    PeerDiscoveryListener? onChanged,
    String? nodeId,
    String? platform,
    List<SessionTransport>? transports,
  })  : onChanged = onChanged,
        nodeId = nodeId ?? _newNodeId(),
        platform = platform ?? Platform.operatingSystem,
        _transports = transports ?? <SessionTransport>[UdpLanTransport(port: port)];

  static const int port = 45892;
  static const String protocol = 'body_finder_peer_v1';
  static const Duration announceEvery = Duration(seconds: 1);
  static const Duration peerTimeout = Duration(seconds: 4);
  static const Duration rangeTimeout = Duration(seconds: 6);

  final PeerDiscoveryListener? onChanged;
  final String nodeId;
  final String platform;
  final List<SessionTransport> _transports;
  final PeerRegistry _registry = PeerRegistry();
  final RelativePositionSolver _positionSolver = const RelativePositionSolver();
  final BootstrapLayoutSolver _bootstrapLayoutSolver = const BootstrapLayoutSolver();
  final Map<String, RangeObservation> _localRanges = {};
  final Map<String, _ReceivedRange> _ranges = {};

  Timer? _announceTimer;
  Timer? _expireTimer;

  bool get isRunning => _transports.any((transport) => transport.isRunning);

  Set<String> get activeTransportIds {
    final ids = <String>{};
    for (final transport in _transports.where((value) => value.isRunning)) {
      if (transport case SessionTransportDiagnostics diagnostics) {
        ids.addAll(diagnostics.activePathIds);
      } else {
        ids.add(transport.id);
      }
    }
    return ids;
  }

  Map<String, String> get transportPathStatuses {
    final statuses = <String, String>{};
    for (final transport in _transports) {
      if (transport case SessionTransportDiagnostics diagnostics) {
        statuses.addAll(diagnostics.pathStatuses);
      } else {
        statuses[transport.id] = transport.isRunning ? 'started' : 'stopped';
      }
    }
    return statuses;
  }

  int get relayedMessageCount => _transports.fold<int>(0, (total, transport) {
        if (transport case SessionTransportDiagnostics diagnostics) {
          return total + diagnostics.relayedMessageCount;
        }
        return total;
      });

  int get duplicateMessageCount => _transports.fold<int>(0, (total, transport) {
        if (transport case SessionTransportDiagnostics diagnostics) {
          return total + diagnostics.duplicateMessageCount;
        }
        return total;
      });

  PeerDiscoverySnapshot get snapshot {
    final activeIds = _registry.peers.map((peer) => peer.id).toSet();
    final metricSolution = _positionSolver.solve(
      activeNodeIds: activeIds,
      observations: _ranges.values.map((stored) => stored.observation),
    );
    final bootstrapSolution = _bootstrapLayoutSolver.solve(activeIds);

    final peers = _registry.peers
        .map((peer) {
          final estimate = metricSolution.positions[peer.id];
          return peer.withEstimatedPosition(
            estimate?.position,
            estimate?.sigmaMeters,
            bootstrapPosition: bootstrapSolution.positions[peer.id],
          );
        })
        .toList()
      ..sort((left, right) => left.id.compareTo(right.id));

    return PeerDiscoverySnapshot(
      localNodeId: nodeId,
      peers: peers,
      coordinatorId: electCoordinator(_registry.peers),
      unresolvedNodeIds: metricSolution.unresolvedNodeIds,
      rangeObservationCount: metricSolution.observationCount,
    );
  }

  Future<void> start() async {
    if (isRunning) return;

    Object? lastError;
    var startedCount = 0;
    for (final transport in _transports) {
      try {
        await transport.start(onMessage: _handleTransportPayload);
        if (transport.isRunning) startedCount++;
      } catch (error) {
        lastError = error;
      }
    }
    if (startedCount == 0) {
      throw StateError(
        'No Body Finder session transport could start${lastError == null ? '' : ': $lastError'}',
      );
    }

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

    for (final transport in _transports) {
      await transport.stop();
    }
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
    _emit();
  }

  void clearLocalRange(String peerNodeId) {
    _localRanges.remove(peerNodeId);
    _ranges.remove(_rangeStorageKey(nodeId, peerNodeId));
    _emit();
  }

  void _handleTransportPayload(Uint8List payload) {
    try {
      final decoded = jsonDecode(utf8.decode(payload));
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
      // Ignore unrelated or malformed traffic from any session transport.
    }
  }

  void _announce() {
    if (!isRunning) return;

    _refreshLocalRecord();
    final now = _nowMicros();
    final refreshedLocalRanges = <RangeObservation>[];
    for (final entry in _localRanges.entries.toList(growable: false)) {
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

    final payload = Uint8List.fromList(utf8.encode(jsonEncode({
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
    })));

    for (final transport in _transports.where((value) => value.isRunning)) {
      unawaited(transport.broadcast(payload));
    }
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
