import 'package:flutter_test/flutter_test.dart';
import 'package:body_finder/infrastructure/ranging/linux_ble_range_adapter.dart';

void main() {
  group('LinuxBleRangeAdapter', () {
    test('parses eight service-data bytes after Body Finder UUID', () {
      const info = '''
Device AA:BB:CC:DD:EE:FF
        RSSI: -63
        ServiceData Key: 93f3b61e-5e3c-4a73-9d10-8fbc5cf4de31
        ServiceData Value:
          0x60 0x54 0xa9 0xf2 0x12 0x34 0xab 0xcd
''';

      expect(
        LinuxBleRangeAdapter.parseNodeIdFromInfo(info),
        '6054a9f21234abcd',
      );
    });

    test('parses compact service-data node id', () {
      const info = '''
ServiceData.93f3b61e-5e3c-4a73-9d10-8fbc5cf4de31: 6054a9f21234abcd
''';
      expect(
        LinuxBleRangeAdapter.parseNodeIdFromInfo(info),
        '6054a9f21234abcd',
      );
    });

    test('parses compact 0x-prefixed service-data node id', () {
      const info = '''
ServiceData.93f3b61e-5e3c-4a73-9d10-8fbc5cf4de31: 0x6054a9f21234abcd
''';
      expect(
        LinuxBleRangeAdapter.parseNodeIdFromInfo(info),
        '6054a9f21234abcd',
      );
    });

    test('parses real BlueZ live service-data byte line', () {
      const line = '''
[bluetooth]#   d9 c6 fb 15 09 03 e0 59                          .......Y
''';
      expect(
        LinuxBleRangeAdapter.parseNodeIdFromServiceDataBytes(line),
        'd9c6fb150903e059',
      );
    });

    test('ignores appended advertisement freshness byte for node identity', () {
      const line = '''
[bluetooth]#   05 c5 fc 0b 12 34 56 78 a7                       ....4Vx.
''';
      expect(
        LinuxBleRangeAdapter.parseNodeIdFromServiceDataBytes(line),
        '05c5fc0b12345678',
      );
    });

    test('parses BlueZ hexadecimal RSSI with signed decimal in parentheses', () {
      const line =
          '[CHG] Device 4F:A2:A5:D3:53:9C RSSI: 0xffffffb1 (-79)';
      expect(LinuxBleRangeAdapter.parseRssiFromScanLine(line), -79);
    });

    test('parses ordinary signed-decimal BlueZ RSSI', () {
      const line = '[CHG] Device 4F:A2:A5:D3:53:9C RSSI: -63';
      expect(LinuxBleRangeAdapter.parseRssiFromScanLine(line), -63);
    });

    test('ignores devices without Body Finder service UUID', () {
      const info = '''
Device AA:BB:CC:DD:EE:FF
        RSSI: -63
        ServiceData Key: 0000180f-0000-1000-8000-00805f9b34fb
        ServiceData Value: 01
''';
      expect(LinuxBleRangeAdapter.parseNodeIdFromInfo(info), isNull);
    });

    test('distance estimate increases as RSSI weakens', () {
      final near = LinuxBleRangeAdapter.estimateDistanceMeters(-55);
      final far = LinuxBleRangeAdapter.estimateDistanceMeters(-80);
      expect(near, lessThan(far));
      expect(near, greaterThanOrEqualTo(0.10));
      expect(far, lessThanOrEqualTo(50.0));
    });

    test('strips terminal ANSI escape sequences', () {
      expect(
        LinuxBleRangeAdapter.stripAnsi('\u001b[0;94m[CHG]\u001b[0m Device'),
        '[CHG] Device',
      );
    });
  });
}
