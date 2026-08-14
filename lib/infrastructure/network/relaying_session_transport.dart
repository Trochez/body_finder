import 'dart:async';
import 'dart:typed_data';

import 'session_transport.dart';

/// Combines multiple communication transports into one logical Body Finder
/// session transport and relays messages between them.
///
/// This class is deliberately transport-only. A child transport being active
/// never implies that its medium contributes physical sensing evidence.
/// Ethernet/LAN, for example, may carry a relayed BLE measurement while still
/// having zero sensing weight itself.
class RelayingSessionTransport
    implements SessionTransport, SessionTransportDiagnostics {
  RelayingSessionTransport(
    Iterable<SessionTransport> transports, {
    this.recentMessageTtl = const Duration(seconds: 15),
  }) : _transports = List<SessionTransport>.unmodifiable(transports) {
    if (_transports.isEmpty) {
      throw ArgumentError.value(
        transports,
        'transports',
        'At least one session transport is required.',
      );
    }
  }

  final List<SessionTransport> _transports;
  final Duration recentMessageTtl;
  final Map<String, DateTime> _recentMessages = <String, DateTime>{};
  final Map<String, String> _pathStatuses = <String, String>{};

  SessionTransportMessageHandler? _onMessage;
  SessionTransportStatusHandler? _onStatus;
  int _relayedMessageCount = 0;
  int _duplicateMessageCount = 0;

  @override
  String get id => 'multiTransportRelay';

  @override
  bool get isRunning => _transports.any((transport) => transport.isRunning);

  Set<String> get activeChildTransportIds => activePathIds;

  @override
  Set<String> get activePathIds {
    final result = <String>{};
    for (final transport in _transports.where((value) => value.isRunning)) {
      if (transport case SessionTransportDiagnostics diagnostics) {
        result.addAll(diagnostics.activePathIds);
      } else {
        result.add(transport.id);
      }
    }
    return result;
  }

  @override
  Map<String, String> get pathStatuses =>
      Map<String, String>.unmodifiable(_pathStatuses);

  @override
  int get relayedMessageCount => _relayedMessageCount;

  @override
  int get duplicateMessageCount => _duplicateMessageCount;

  @override
  Future<void> start({
    required SessionTransportMessageHandler onMessage,
    SessionTransportStatusHandler? onStatus,
  }) async {
    if (isRunning) return;
    _onMessage = onMessage;
    _onStatus = onStatus;
    _recentMessages.clear();
    _pathStatuses.clear();
    _relayedMessageCount = 0;
    _duplicateMessageCount = 0;

    Object? lastError;
    var started = 0;
    for (final transport in _transports) {
      try {
        await transport.start(
          onMessage: (payload) => _receiveFrom(transport, payload),
          onStatus: (status) {
            _pathStatuses[transport.id] = status;
            _onStatus?.call('${transport.id}:$status');
          },
        );
        if (transport.isRunning) {
          started++;
          _pathStatuses.putIfAbsent(transport.id, () => 'started');
        } else {
          _pathStatuses.putIfAbsent(transport.id, () => 'notRunning');
        }
      } catch (error) {
        lastError = error;
        _pathStatuses[transport.id] = 'failed';
        _onStatus?.call('${transport.id}:failed');
      }
    }

    if (started == 0) {
      _onMessage = null;
      _onStatus = null;
      throw StateError(
        'No child session transport could start'
        '${lastError == null ? '' : ': $lastError'}',
      );
    }
    _onStatus?.call('started');
  }

  @override
  Future<void> broadcast(Uint8List payload) async {
    if (payload.isEmpty || !isRunning) return;
    _remember(payload);
    await _broadcastToChildren(payload);
  }

  @override
  Future<void> stop() async {
    for (final transport in _transports) {
      try {
        await transport.stop();
        _pathStatuses[transport.id] = 'stopped';
      } catch (_) {
        _pathStatuses[transport.id] = 'stopFailed';
      }
    }
    _recentMessages.clear();
    _onMessage = null;
    _onStatus = null;
  }

  void _receiveFrom(SessionTransport source, Uint8List payload) {
    if (payload.isEmpty) return;
    _expireRecent();
    final fingerprint = _fingerprint(payload);
    if (_recentMessages.containsKey(fingerprint)) {
      _duplicateMessageCount++;
      return;
    }
    _recentMessages[fingerprint] = DateTime.now();

    _onMessage?.call(Uint8List.fromList(payload));

    final targets = _transports
        .where((transport) => !identical(transport, source) && transport.isRunning)
        .toList(growable: false);
    if (targets.isEmpty) return;
    _relayedMessageCount++;
    for (final target in targets) {
      unawaited(_safeBroadcast(target, payload));
    }
  }

  Future<void> _broadcastToChildren(Uint8List payload) async {
    await Future.wait(
      _transports
          .where((transport) => transport.isRunning)
          .map((transport) => _safeBroadcast(transport, payload)),
    );
  }

  Future<void> _safeBroadcast(
    SessionTransport transport,
    Uint8List payload,
  ) async {
    try {
      await transport.broadcast(Uint8List.fromList(payload));
    } catch (_) {
      _pathStatuses[transport.id] = 'sendFailed';
      _onStatus?.call('${transport.id}:sendFailed');
    }
  }

  void _remember(Uint8List payload) {
    _expireRecent();
    _recentMessages[_fingerprint(payload)] = DateTime.now();
  }

  void _expireRecent() {
    final cutoff = DateTime.now().subtract(recentMessageTtl);
    _recentMessages.removeWhere((_, seenAt) => seenAt.isBefore(cutoff));
  }

  /// Small deterministic FNV-1a fingerprint used only for short-lived loop
  /// suppression. This is not a security or identity primitive.
  static String _fingerprint(Uint8List bytes) {
    const offset = 0xcbf29ce484222325;
    const prime = 0x100000001b3;
    const mask = 0xffffffffffffffff;
    var hash = offset;
    for (final byte in bytes) {
      hash ^= byte;
      hash = (hash * prime) & mask;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }
}
