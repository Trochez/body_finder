import 'dart:typed_data';

typedef SessionTransportMessageHandler = void Function(Uint8List payload);
typedef SessionTransportStatusHandler = void Function(String status);

/// Transport contract for Body Finder session/control traffic.
///
/// A transport only moves session messages. It does not imply that the
/// underlying medium contributes physical sensing evidence. For example,
/// Ethernet/LAN can implement this interface while still having zero sensing
/// weight in body/anomaly detection.
abstract interface class SessionTransport {
  String get id;
  bool get isRunning;

  Future<void> start({
    required SessionTransportMessageHandler onMessage,
    SessionTransportStatusHandler? onStatus,
  });

  Future<void> broadcast(Uint8List payload);

  Future<void> stop();
}
