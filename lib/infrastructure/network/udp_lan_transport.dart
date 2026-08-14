import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'session_transport.dart';

/// Opportunistic IP fast path for session/control traffic.
///
/// This transport is never treated as a physical sensing source. It only
/// carries messages when participants happen to share an IPv4 broadcast LAN.
class UdpLanTransport implements SessionTransport {
  UdpLanTransport({required this.port});

  final int port;
  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _subscription;
  SessionTransportMessageHandler? _onMessage;

  @override
  String get id => 'lanUdp';

  @override
  bool get isRunning => _socket != null;

  @override
  Future<void> start({
    required SessionTransportMessageHandler onMessage,
    SessionTransportStatusHandler? onStatus,
  }) async {
    if (isRunning) return;
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      port,
      reuseAddress: true,
    );
    socket.broadcastEnabled = true;
    _socket = socket;
    _onMessage = onMessage;
    _subscription = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? datagram;
      while ((datagram = socket.receive()) != null) {
        onMessage(Uint8List.fromList(datagram!.data));
      }
    });
    onStatus?.call('started');
  }

  @override
  Future<void> broadcast(Uint8List payload) async {
    final socket = _socket;
    if (socket == null) return;
    socket.send(payload, InternetAddress('255.255.255.255'), port);
  }

  @override
  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    _socket?.close();
    _socket = null;
    _onMessage = null;
  }
}
