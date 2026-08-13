import 'package:body_finder/application/orchestration/capability_ranker.dart';
import 'package:body_finder/domain/capability/sensor_capability.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ready exposed capabilities rank above restricted ones', () {
    const ready = SensorCapability(
      type: SensorType.accelerometer,
      hardwareAvailable: true,
      apiAvailable: true,
      permissionState: PermissionState.notRequired,
      measurementAvailable: true,
      capabilityClass: CapabilityClass.commonAndExposed,
      estimatedQuality: 0.8,
    );
    const restricted = SensorCapability(
      type: SensorType.rawUwb,
      hardwareAvailable: true,
      apiAvailable: false,
      permissionState: PermissionState.unknown,
      measurementAvailable: false,
      capabilityClass: CapabilityClass.hardwareApiRestricted,
      estimatedQuality: 1,
    );

    final ranked = rankCapabilities([restricted, ready]);
    expect(ranked.first.capability.type, SensorType.accelerometer);
    expect(ranked.last.score, 0);
  });
}
