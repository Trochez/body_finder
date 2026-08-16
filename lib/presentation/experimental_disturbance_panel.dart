import 'package:flutter/material.dart';

import '../application/sensing/rssi_disturbance_tracker.dart';

class ExperimentalDisturbancePanel extends StatelessWidget {
  const ExperimentalDisturbancePanel({
    super.key,
    required this.snapshot,
    required this.sensingReady,
    required this.onCalibrate,
  });

  final RssiDisturbanceSnapshot snapshot;

  /// Latched mobile-sensing eligibility for this session. This deliberately
  /// does not depend on the instantaneous BLE-derived metric frame because
  /// RSSI geometry can temporarily become unresolved while the same phones
  /// and physical RSSI links remain usable for disturbance monitoring.
  final bool sensingReady;
  final VoidCallback? onCalibrate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.radar),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Collective experimental RF disturbance',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                _PhaseChip(phase: snapshot.phase),
              ],
            ),
            const SizedBox(height: 10),
            const Text(
              'Combines direct BLE RSSI measurements reported by the phones in this session and compares them with a fixed-scene baseline. '
              'This measures RF change only; it is not proof that a person is present. A quiet result never proves absence.',
            ),
            const SizedBox(height: 16),
            if (!sensingReady && snapshot.phase == DisturbancePhase.idle) ...[
              const Text(
                'Waiting for 3 phones plus at least two fresh physical RF edges covering the three devices. The metric map is not required for RF baseline calibration.',
              ),
            ] else if (snapshot.phase == DisturbancePhase.idle ||
                snapshot.phase == DisturbancePhase.stale) ...[
              if (snapshot.phase == DisturbancePhase.stale)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text(
                    'A different phone joined the calibrated topology. Capture a new baseline before interpreting disturbance values.',
                  ),
                ),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: onCalibrate,
                  icon: const Icon(Icons.tune),
                  label: const Text('Calibrate shared RF baseline'),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Keep all phones fixed and keep the scene as unchanged as possible during calibration. '
                'Calibration uses the fresh RF streams currently shared by the mesh. '
                'A person already present during calibration may become part of the baseline.',
              ),
            ] else if (snapshot.phase == DisturbancePhase.calibrating) ...[
              Text(
                'Calibrating ${(snapshot.baselineProgress * 100).round()}% — keep phones and scene still.',
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              LinearProgressIndicator(value: snapshot.baselineProgress),
              const SizedBox(height: 8),
              const Text(
                'Calibration switches to monitoring automatically when every selected shared RF stream has enough samples.',
              ),
            ] else ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.sensors,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'MONITORING ACTIVE — shared RF streams are being scored automatically. Keep all phones fixed.',
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: theme.colorScheme.onPrimaryContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _OverallDisturbance(snapshot: snapshot),
              const SizedBox(height: 16),
              if (snapshot.links.isEmpty)
                const Text('Waiting for fresh shared BLE RSSI samples…')
              else
                ...snapshot.links.map(
                  (link) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _LinkDisturbanceTile(link: link),
                  ),
                ),
              const Divider(),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: onCalibrate,
                  icon: const Icon(Icons.restart_alt),
                  label: const Text('Capture a new shared baseline'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _OverallDisturbance extends StatelessWidget {
  const _OverallDisturbance({required this.snapshot});

  final RssiDisturbanceSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final score = (snapshot.overallScore * 100).round();
    final quality = (snapshot.overallQuality * 100).round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Shared RF disturbance index: $score / 100',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 6),
        LinearProgressIndicator(value: snapshot.overallScore),
        const SizedBox(height: 8),
        Text('Evidence quality: $quality / 100'),
        const SizedBox(height: 4),
        const Text(
          'Index = change from this session baseline, not probability of a body or survivor.',
        ),
      ],
    );
  }
}

class _LinkDisturbanceTile extends StatelessWidget {
  const _LinkDisturbanceTile({required this.link});

  final LinkDisturbance link;

  @override
  Widget build(BuildContext context) {
    final score = (link.score * 100).round();
    final ageSeconds = link.age.inMilliseconds / 1000;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _linkLabel(link.peerNodeId),
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            Text('$score / 100'),
          ],
        ),
        const SizedBox(height: 4),
        LinearProgressIndicator(value: link.score),
        const SizedBox(height: 4),
        Text(
          'RSSI ${link.rssiDbm.toStringAsFixed(1)} dBm · baseline '
          '${link.baselineRssiDbm.toStringAsFixed(1)} dBm · '
          'noise σ ${link.baselineSigmaDb.toStringAsFixed(1)} dB · '
          '${ageSeconds.toStringAsFixed(1)} s old',
        ),
      ],
    );
  }

  static String _linkLabel(String value) {
    final parts = value.split('->');
    if (parts.length == 2) {
      return 'RF ${_shortId(parts[0])} → ${_shortId(parts[1])}';
    }
    return 'RF ${_shortId(value)}';
  }

  static String _shortId(String value) =>
      value.length <= 8 ? value : value.substring(0, 8);
}

class _PhaseChip extends StatelessWidget {
  const _PhaseChip({required this.phase});

  final DisturbancePhase phase;

  @override
  Widget build(BuildContext context) {
    final text = switch (phase) {
      DisturbancePhase.idle => 'NOT CALIBRATED',
      DisturbancePhase.calibrating => 'CALIBRATING',
      DisturbancePhase.monitoring => 'MONITORING ACTIVE',
      DisturbancePhase.stale => 'RECALIBRATE',
    };
    return Chip(label: Text(text));
  }
}
