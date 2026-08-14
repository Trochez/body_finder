import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../application/session/coordinator_election.dart';
import '../../application/session/peer_registry.dart';
import '../../domain/geometry/vec2.dart';

class PeerDiscoverySnapshot {
  const PeerDiscoverySnapshot({
    required this.localNodeId,
    required this.peers,
    required this.coordinatorId,
  });

  final String localNodeId;
  final List<PeerRecord> peers;
  final String? coordinatorId;

  int get nodeCount => peers.length;
  int get phoneCount => nodeCount;
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

  final PeerDiscoveryListener? onChanged;
  final String nodeId;
  final String platform;
  final PeerRegistry _registry = PeerRegistry();

  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _socketSubscription;
  Timer? _announceTimer;
  Timer? _expireTimer;
  Vec2? _localPosition;

  bool get isRunning => _socket != null;
  Vec2? get localPosition => _localPosition;

  PeerDiscoverySnapshot get snapshot => PeerDiscoverySnapshot(
        localNodeId: nodeId,
        peers: _sortedPeers(),
        coordinatorId: electCoordinator(_registry.peers),
      );

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
      (_) => _expireStalePeers(),
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

  void updateLocalPosition(Vec2? position) {
    _localPosition = position;
    _refreshLocalRecord();
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
      final hasPosition = decoded.containsKey('position');
      final remotePosition = _decodePosition(decoded['position']);
      _registry.seen(
        remoteNodeId,
        _nowMicros(),
        platform: remotePlatform is String ? remotePlatform : null,
        position: remotePosition,
        positionProvided: hasPosition,
      );
      _emit();
    } on FormatException {
      // Ignore unrelated LAN traffic on the discovery port.
    }
  }

  void _announce() {
    final socket = _socket;
    if (socket == null) return;

    _refreshLocalRecord();
    final payload = utf8.encode(jsonEncode({
      'protocol': protocol,
      'nodeId': nodeId,
      'platform': platform,
      'position': _localPosition?.toJson(),
      'timestampMicros': _nowMicros(),
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
      position: _localPosition,
      positionProvided: true,
    );
  }

  void _expireStalePeers() {
    final cutoff = _nowMicros() - peerTimeout.inMicroseconds;
    final expired = _registry.expireBefore(cutoff);
    _refreshLocalRecord();
    if (expired.isNotEmpty) _emit();
  }

  List<PeerRecord> _sortedPeers() {
    final peers = _registry.peers.toList()
      ..sort((left, right) => left.id.compareTo(right.id));
    return peers;
  }

  void _emit() => onChanged?.call(snapshot);

  static Vec2? _decodePosition(Object? raw) {
    if (raw is! Map) return null;
    final x = raw['x'];
    final y = raw['y'];
    if (x is! num || y is! num) return null;
    return Vec2(x.toDouble(), y.toDouble());
  }

  static int _nowMicros() => DateTime.now().microsecondsSinceEpoch;

  static String _newNodeId() {
    final random = Random.secure();
    final first = random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
    final second = random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
    return '$first$second';
  }
}
