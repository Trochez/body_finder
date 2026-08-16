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

  test('temporary loss of a calibrated peer preserves monitoring baseline', () {
    final tracker = RssiDisturbanceTracker(minimumBaselineSamples: 5);
    tracker.startCalibration(const ['peer-a', 'peer-b']);
    for (var i = 0; i < 5; i++) {
      tracker.addSample(peerNodeId: 'peer-a', rssiDbm: -60);
      tracker.addSample(peerNodeId: 'peer-b', rssiDbm: -65);
    }
    expect(tracker.snapshot().phase, DisturbancePhase.monitoring);

    tracker.reconcilePeers(const ['peer-a']);

    expect(tracker.snapshot().phase, DisturbancePhase.monitoring);
    expect(tracker.snapshot().requiredPeerIds, containsAll(['peer-a', 'peer-b']));
  });

  test('a different replacement peer marks captured baseline stale', () {
    final tracker = RssiDisturbanceTracker(minimumBaselineSamples: 5);
    tracker.startCalibration(const ['peer-a', 'peer-b']);
    for (var i = 0; i < 5; i++) {
      tracker.addSample(peerNodeId: 'peer-a', rssiDbm: -60);
      tracker.addSample(peerNodeId: 'peer-b', rssiDbm: -65);
    }
    expect(tracker.snapshot().phase, DisturbancePhase.monitoring);

    tracker.reconcilePeers(const ['peer-a', 'peer-c']);

    expect(tracker.snapshot().phase, DisturbancePhase.stale);
  });

  test('stale RF stream contributes no evidence instead of freezing score', () {
    final tracker = RssiDisturbanceTracker(minimumBaselineSamples: 5);
    final start = DateTime(2026, 1, 1, 12);
    tracker.startCalibration(const ['peer-a']);
    for (var i = 0; i < 5; i++) {
      tracker.addSample(
        peerNodeId: 'peer-a',
        rssiDbm: -60,
        observedAt: start.add(Duration(milliseconds: i * 100)),
      );
    }
    tracker.addSample(
      peerNodeId: 'peer-a',
      rssiDbm: -72,
      observedAt: start.add(const Duration(seconds: 1)),
    );

    final fresh = tracker.snapshot(now: start.add(const Duration(seconds: 2)));
    expect(fresh.hasFreshEvidence, isTrue);
    expect(fresh.overallScore, greaterThan(0.5));

    final stale = tracker.snapshot(now: start.add(const Duration(seconds: 5)));
    expect(stale.links.single.isFresh, isFalse);
    expect(stale.hasFreshEvidence, isFalse);
    expect(stale.overallScore, 0);
    expect(stale.overallQuality, 0);
  });

  test('reacquired RF stream restarts smoothing instead of carrying stale score', () {
    final tracker = RssiDisturbanceTracker(minimumBaselineSamples: 5);
    final start = DateTime(2026, 1, 1, 12);
    tracker.startCalibration(const ['peer-a']);
    for (var i = 0; i < 5; i++) {
      tracker.addSample(
        peerNodeId: 'peer-a',
        rssiDbm: -60,
        observedAt: start.add(Duration(milliseconds: i * 100)),
      );
    }
    for (var i = 0; i < 5; i++) {
      tracker.addSample(
        peerNodeId: 'peer-a',
        rssiDbm: -72,
        observedAt: start.add(Duration(seconds: 1, milliseconds: i * 100)),
      );
    }
    expect(
      tracker.snapshot(now: start.add(const Duration(seconds: 2))).links.single.score,
      greaterThan(0.7),
    );

    tracker.addSample(
      peerNodeId: 'peer-a',
      rssiDbm: -60,
      observedAt: start.add(const Duration(seconds: 6)),
    );

    final recovered = tracker.snapshot(now: start.add(const Duration(seconds: 6)));
    expect(recovered.links.single.isFresh, isTrue);
    expect(recovered.links.single.score, lessThan(0.1));
  });
}
