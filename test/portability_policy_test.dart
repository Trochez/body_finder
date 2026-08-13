import 'package:body_finder/application/orchestration/portability_policy.dart';
import 'package:body_finder/domain/capability/sensor_capability.dart';
import 'package:flutter_test/flutter_test.dart';

SensorCapability capability(SensorType type, {bool available = true}) => SensorCapability(
      type: type,
      hardwareAvailable: available,
      apiAvailable: available,
      permissionState: PermissionState.granted,
      measurementAvailable: available,
      capabilityClass: available ? CapabilityClass.commonAndExposed : CapabilityClass.unavailable,
      estimatedQuality: available ? 0.8 : 0,
    );

NodeCapabilities node(List<SensorType> sensors) => NodeCapabilities(
      platform: 'test',
      platformVersion: '1',
      capabilities: sensors.map(capability).toList(),
    );

void main() {
  test('BLE plus common phone sensors selects universal mode', () {
    final profile = selectOperatingProfile(node([
      SensorType.bluetoothLowEnergy,
      SensorType.wifi,
      SensorType.accelerometer,
    ]));

    expect(profile.mode, OperatingMode.universal);
    expect(profile.participationAllowed, isTrue);
  });

  test('missing UWB and RTT never rejects a compatible phone', () {
    final profile = selectOperatingProfile(node([
      SensorType.bluetoothLowEnergy,
      SensorType.gyroscope,
    ]));

    expect(profile.mode, OperatingMode.universal);
    expect(profile.participationAllowed, isTrue);
  });

  test('minimal hardware still participates in limited mode', () {
    final profile = selectOperatingProfile(node([SensorType.bluetoothLowEnergy]));

    expect(profile.mode, OperatingMode.limited);
    expect(profile.participationAllowed, isTrue);
  });

  test('UWB and RTT enhance rather than define compatibility', () {
    final profile = selectOperatingProfile(node([
      SensorType.bluetoothLowEnergy,
      SensorType.wifi,
      SensorType.wifiRtt,
      SensorType.uwbRanging,
    ]));

    expect(profile.mode, OperatingMode.advanced);
  });
}
