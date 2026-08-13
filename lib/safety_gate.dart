enum EvidenceLabel {
  provenRelevantEnvironment,
  demonstratedLab,
  supportedIndirectly,
  theoretical,
  speculative,
}

enum SafetyStatus { anomaly, unavailable }

class SafetyGate {
  SafetyGate({required this.evidence, required this.anomalyScore}) {
    if (anomalyScore < 0 || anomalyScore > 1) {
      throw ArgumentError.value(anomalyScore, 'anomalyScore', 'must be between 0 and 1');
    }
  }

  final EvidenceLabel evidence;
  final double anomalyScore;

  SafetyStatus get status => switch (evidence) {
    EvidenceLabel.provenRelevantEnvironment || EvidenceLabel.demonstratedLab =>
      SafetyStatus.anomaly,
    EvidenceLabel.supportedIndirectly ||
    EvidenceLabel.theoretical ||
    EvidenceLabel.speculative => SafetyStatus.unavailable,
  };

  String get message => switch (status) {
    SafetyStatus.anomaly => 'Anomaly hypothesis; uncertainty remains.',
    SafetyStatus.unavailable =>
      'Unavailable: not proof of presence or absence.',
  };
}
