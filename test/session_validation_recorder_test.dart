import 'package:body_finder/application/diagnostics/session_validation_recorder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('aggregates one consolidated hardware validation session', () {
    final recorder = SessionValidationRecorder();

    recorder.recordTopology(
      nodeIds: const <String>['a', 'b'],
      metricNodeCount: 2,
      rangeEdgeCount: 1,
    );
    recorder.recordTopology(
      nodeIds: const <String>['a', 'b', 'c'],
      metricNodeCount: 2,
      rangeEdgeCount: 1,
    );
    recorder.recordTransports(const <String>['bleControl']);
    recorder.recordTransports(const <String>['lanUdp', 'bleControl']);
    recorder.recordPhysicalRange(
      peerNodeId: 'b',
      source: 'bleRssi',
      distanceMeters: 0.49,
      sigmaMeters: 1.0,
      rssiDbm: -50,
      observedAtMicros: 1,
    );
    recorder.recordPhysicalRange(
      peerNodeId: 'b',
      source: 'bleRssi',
      distanceMeters: 11.67,
      sigmaMeters: 8.75,
      rssiDbm: -82,
      observedAtMicros: 2,
    );
    recorder.recordTransportDiagnostics(
      pathStatuses: const <String, String>{
        'bleControl': 'peerSubscribed',
        'lanUdp': 'started',
      },
      relayedMessageCount: 12,
      duplicateMessageCount: 5,
    );

    final report = recorder.report;
    expect(report.maxNodeCount, 3);
    expect(report.maxMetricNodeCount, 2);
    expect(report.maxRangeEdgeCount, 1);
    expect(report.rangeSampleCount, 2);
    expect(report.observedTransportIds, containsAll(<String>{'bleControl', 'lanUdp'}));
    expect(report.transportStatuses['bleControl'], 'peerSubscribed');
    expect(report.transportStatuses['lanUdp'], 'started');
    expect(report.minDistanceMeters, 0.49);
    expect(report.maxDistanceMeters, 11.67);
    expect(report.minRssiDbm, -82);
    expect(report.maxRssiDbm, -50);
    expect(report.relayedMessageCount, 12);
    expect(report.duplicateMessageCount, 5);
    expect(report.latestRangesByPeer['b']?.distanceMeters, 11.67);
    expect(report.toPlainText(), contains('bleControl=peerSubscribed'));
    expect(report.toPlainText(), contains('not proof of body presence or absence'));
  });

  test('invalid physical samples are ignored', () {
    final recorder = SessionValidationRecorder();
    recorder.recordPhysicalRange(
      peerNodeId: 'peer',
      source: 'bleRssi',
      distanceMeters: -1,
      sigmaMeters: 1,
      rssiDbm: -60,
    );

    expect(recorder.report.rangeSampleCount, 0);
  });
}
