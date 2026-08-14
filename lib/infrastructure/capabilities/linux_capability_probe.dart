import 'dart:io';

import '../../domain/capability/sensor_capability.dart';

class LinuxCapabilityProbe {
  const LinuxCapabilityProbe();

  Future<Map<Object?, Object?>> scan() async {
    final bluetooth = await _bluetoothState();
    final wifi = await _wifiState();
    final isWsl = Platform.operatingSystemVersion.toLowerCase().contains('microsoft') ||
        await _fileContains('/proc/version', 'microsoft');

    return <Object?, Object?>{
      'platform': 'linux',
      'platformVersion': Platform.operatingSystemVersion,
      'capabilities': <Object?>[
        _capability(
          SensorType.bluetoothLowEnergy,
          hardware: bluetooth.controllerPresent,
          api: bluetooth.bluezAvailable,
          permission: bluetooth.controllerPresent
              ? PermissionState.notRequired
              : PermissionState.unknown,
          measurement: bluetooth.controllerPresent && bluetooth.powered,
          capabilityClass: bluetooth.controllerPresent
              ? CapabilityClass.commonAndExposed
              : CapabilityClass.unavailable,
          quality: bluetooth.controllerPresent ? 0.45 : 0.0,
          reason: bluetooth.reason ??
              (isWsl && !bluetooth.controllerPresent
                  ? 'No Bluetooth controller is exposed inside WSL. Use native Linux, USB passthrough, or a native Windows participant for BLE ranging.'
                  : null),
        ),
        _capability(
          SensorType.wifi,
          hardware: wifi.interfacePresent,
          api: wifi.interfacePresent,
          permission: PermissionState.notRequired,
          measurement: wifi.interfacePresent,
          capabilityClass: wifi.interfacePresent
              ? CapabilityClass.commonAndExposed
              : CapabilityClass.unavailable,
          quality: wifi.interfacePresent ? 0.40 : 0.0,
          reason: wifi.reason ??
              (isWsl && !wifi.interfacePresent
                  ? 'The WSL guest is using a virtual network interface; the host Wi-Fi radio is not directly exposed as a Linux wireless interface.'
                  : null),
        ),
        _capability(
          SensorType.wifiRtt,
          hardware: wifi.interfacePresent,
          api: false,
          permission: PermissionState.notRequired,
          measurement: false,
          capabilityClass: CapabilityClass.hardwareApiRestricted,
          quality: 0,
          reason: wifi.interfacePresent
              ? 'No generic Linux Wi-Fi RTT adapter is implemented yet.'
              : 'No Linux wireless interface is exposed.',
        ),
        _capability(
          SensorType.wifiCsi,
          hardware: wifi.interfacePresent,
          api: false,
          permission: PermissionState.notRequired,
          measurement: false,
          capabilityClass: CapabilityClass.researchOnly,
          quality: 0,
          reason: 'Raw CSI is not assumed available through a universal Linux API.',
        ),
        _capability(
          SensorType.uwbRanging,
          hardware: false,
          api: false,
          permission: PermissionState.notRequired,
          measurement: false,
          capabilityClass: CapabilityClass.unavailable,
          quality: 0,
          reason: 'No generic Linux UWB ranging provider is configured.',
        ),
        _capability(
          SensorType.rawUwb,
          hardware: false,
          api: false,
          permission: PermissionState.notRequired,
          measurement: false,
          capabilityClass: CapabilityClass.researchOnly,
          quality: 0,
          reason: 'No raw UWB provider is configured.',
        ),
        ...SensorType.values
            .where((type) => const {
                  SensorType.accelerometer,
                  SensorType.gyroscope,
                  SensorType.magnetometer,
                  SensorType.barometer,
                  SensorType.gnss,
                  SensorType.microphone,
                }.contains(type))
            .map(
              (type) => _capability(
                type,
                hardware: false,
                api: false,
                permission: PermissionState.unknown,
                measurement: false,
                capabilityClass: CapabilityClass.unavailable,
                quality: 0,
                reason: 'No Linux provider is implemented for ${type.name} yet.',
              ),
            ),
      ],
    };
  }

  Future<_BluetoothState> _bluetoothState() async {
    try {
      final result = await Process.run('bluetoothctl', const ['list']);
      if (result.exitCode != 0) {
        return const _BluetoothState(
          bluezAvailable: true,
          controllerPresent: false,
          powered: false,
          reason: 'BlueZ is installed but no accessible Bluetooth controller was returned.',
        );
      }
      final output = '${result.stdout}';
      final controllerPresent = output.contains('Controller ');
      if (!controllerPresent) {
        return const _BluetoothState(
          bluezAvailable: true,
          controllerPresent: false,
          powered: false,
          reason: 'BlueZ is available, but no Bluetooth controller is exposed to this Linux instance.',
        );
      }
      final show = await Process.run('bluetoothctl', const ['show']);
      final powered = show.exitCode == 0 && '${show.stdout}'.contains('Powered: yes');
      return _BluetoothState(
        bluezAvailable: true,
        controllerPresent: true,
        powered: powered,
        reason: powered ? null : 'Bluetooth controller is present but powered off.',
      );
    } on ProcessException {
      return const _BluetoothState(
        bluezAvailable: false,
        controllerPresent: false,
        powered: false,
        reason: 'BlueZ bluetoothctl is not installed or not reachable.',
      );
    }
  }

  Future<_WifiState> _wifiState() async {
    try {
      final interfaces = await Directory('/sys/class/net').list().toList();
      for (final entity in interfaces) {
        final wireless = Directory('${entity.path}/wireless');
        if (await wireless.exists()) {
          return const _WifiState(interfacePresent: true);
        }
      }
      return const _WifiState(
        interfacePresent: false,
        reason: 'No Linux wireless interface is exposed under /sys/class/net.',
      );
    } on FileSystemException {
      return const _WifiState(
        interfacePresent: false,
        reason: 'Linux wireless-interface state could not be inspected.',
      );
    }
  }

  Future<bool> _fileContains(String path, String needle) async {
    try {
      final value = await File(path).readAsString();
      return value.toLowerCase().contains(needle.toLowerCase());
    } on FileSystemException {
      return false;
    }
  }

  Map<Object?, Object?> _capability(
    SensorType type, {
    required bool hardware,
    required bool api,
    required PermissionState permission,
    required bool measurement,
    required CapabilityClass capabilityClass,
    required double quality,
    String? reason,
  }) =>
      <Object?, Object?>{
        'sensorType': type.name,
        'hardwareAvailable': hardware,
        'apiAvailable': api,
        'permissionState': permission.name,
        'measurementAvailable': measurement,
        'capabilityClass': capabilityClass.name,
        'estimatedQuality': quality,
        if (reason != null) 'restrictionReason': reason,
      };
}

class _BluetoothState {
  const _BluetoothState({
    required this.bluezAvailable,
    required this.controllerPresent,
    required this.powered,
    this.reason,
  });

  final bool bluezAvailable;
  final bool controllerPresent;
  final bool powered;
  final String? reason;
}

class _WifiState {
  const _WifiState({required this.interfacePresent, this.reason});

  final bool interfacePresent;
  final String? reason;
}
