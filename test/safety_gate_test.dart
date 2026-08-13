import 'package:flutter_test/flutter_test.dart';

import 'package:body_finder/safety_gate.dart';

void main() {
  test('target claims remain unavailable without evidence', () {
    final gate = SafetyGate(
      evidence: EvidenceLabel.theoretical,
      anomalyScore: 0.99,
    );

    expect(gate.status, SafetyStatus.unavailable);
    expect(gate.message, contains('not proof'));
  });

  test('validated anomaly preserves bounded score', () {
    final gate = SafetyGate(
      evidence: EvidenceLabel.demonstratedLab,
      anomalyScore: 0.75,
    );

    expect(gate.status, SafetyStatus.anomaly);
    expect(gate.anomalyScore, 0.75);
  });

  test('rejects scores outside normalized range', () {
    expect(
      () => SafetyGate(
        evidence: EvidenceLabel.demonstratedLab,
        anomalyScore: 1.1,
      ),
      throwsArgumentError,
    );
  });
}
