import 'package:body_finder/application/sensing/rssi_disturbance_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('requires every expected peer before baseline becomes ready', () {
    final tracker = RssiDisturbanceTracker(minimumBaselineSamples: 5);
    tracker.startCalibration(const ['peer-a', 'peer-b']);

    for (var i = 0; i < 5; i++) {
      tracker.addSample(peerNodeId: 'peer-a', rssiDbm: -60 + i * 0.1);
    }

    expect(tracker.snapshot().phase, DisturbancePhase.calibrating);
    expect(tracker.snapshot().baselineProgress, 0);

    for (var i = 0; i < 5; i++) {
      tracker.addSample(peerNodeId: 'peer-b', rssiDbm: -64 + i * 0.1);
    }

    expect(tracker.snapshot().phase, DisturbancePhase.monitoring);
    expect(tracker.snapshot().baselineProgress, 1);
  });

  test('stable post-baseline RSSI stays low disturbance', () {
    final tracker = RssiDisturbanceTracker(minimumBaselineSamples: 8);
    tracker.startCalibration(const ['peer-a']);

    const baseline = [-60.0, -59.5, -60.5, -60.2, -59.8, -60.1, -59.9, -60.3];
    for (final value in baseline) {
      tracker.addSample(peerNodeId: 'peer-a', rssiDbm: value);
    }
    for (var i = 0; i < 12; i++) {
      tracker.addSample(
        peerNodeId: 'peer-a',
        rssiDbm: -60 + (i.isEven ? 0.4 : -0.4),
      );
    }

    final snapshot = tracker.snapshot();
    expect(snapshot.phase, DisturbancePhase.monitoring);
    expect(snapshot.links, hasLength(1));
    expect(snapshot.links.single.score, lessThan(0.15));
    expect(snapshot.overallScore, lessThan(0.15));
  });

  test('large sustained RSSI change produces high disturbance', () {
    final tracker = RssiDisturbanceTracker(minimumBaselineSamples: 8);
    tracker.startCalibration(const ['peer-a']);

    for (var i = 0; i < 8; i++) {
      tracker.addSample(
        peerNodeId: 'peer-a',
        rssiDbm: -60 + (i.isEven ? 0.3 : -0.3),
      );
    }
    for (var i = 0; i < 14; i++) {
      tracker.addSample(peerNodeId: 'peer-a', rssiDbm: -72);
    }

    final snapshot = tracker.snapshot();
    expect(snapshot.links.single.score, greaterThan(0.75));
    expect(snapshot.overallScore, greaterThan(0.65));
  });

  test('topology change marks a captured baseline stale', () {
    final tracker = RssiDisturbanceTracker(minimumBaselineSamples: 5);
    tracker.startCalibration(const ['peer-a', 'peer-b']);
    for (var i = 0; i < 5; i++) {
      tracker.addSample(peerNodeId: 'peer-a', rssiDbm: -60);
      tracker.addSample(peerNodeId: 'peer-b', rssiDbm: -65);
    }
    expect(tracker.snapshot().phase, DisturbancePhase.monitoring);

    tracker.reconcilePeers(const ['peer-a']);

    expect(tracker.snapshot().phase, DisturbancePhase.stale);
  });
}
