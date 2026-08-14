import 'dart:io';

import 'android_ble_session_platform_adapter.dart';
import 'ble_session_transport.dart';
import 'linux_bluez_session_platform_adapter.dart';
import 'relaying_session_transport.dart';
import 'session_transport.dart';
import 'udp_lan_transport.dart';

SessionTransport createDefaultSessionTransport({
  required String nodeId,
  required int lanPort,
}) {
  final children = <SessionTransport>[
    UdpLanTransport(port: lanPort),
  ];

  if (Platform.isAndroid) {
    children.add(
      BleSessionTransport(
        nodeId: nodeId,
        platformAdapter: AndroidBleSessionPlatformAdapter(),
      ),
    );
  } else if (Platform.isLinux) {
    children.add(
      BleSessionTransport(
        nodeId: nodeId,
        platformAdapter: LinuxBluezSessionPlatformAdapter(),
      ),
    );
  }

  return RelayingSessionTransport(children);
}
