import 'package:flutter/material.dart';

import '../application/sensing/rssi_disturbance_tracker.dart';

class ExperimentalDisturbancePanel extends StatelessWidget {
  const ExperimentalDisturbancePanel({
    super.key,
    required this.snapshot,
    required this.geometryReady,
    required this.onCalibrate,
  });

  final RssiDisturbanceSnapshot snapshot;
  final bool geometryReady;
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
                    'Experimental RF disturbance',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                _PhaseChip(phase: snapshot.phase),
              ],
            ),
            const SizedBox(height: 10),
            const Text(
              'Compares live BLE RSSI against a baseline captured with the phones fixed in place. '
              'This measures RF change only; it is not proof that a person is present. A quiet result never proves absence.',
            ),
            const SizedBox(height: 16),
            if (!geometryReady) ...[
              const Text(
                'Waiting for a 3-node metric frame and three physical range edges before calibration.',
              ),
            ] else if (snapshot.phase == DisturbancePhase.idle ||
                snapshot.phase == DisturbancePhase.stale) ...[
              if (snapshot.phase == DisturbancePhase.stale)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text(
                    'Node membership changed. Capture a new baseline before interpreting disturbance values.',
                  ),
                ),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: onCalibrate,
                  icon: const Icon(Icons.tune),
                  label: const Text('Calibrate RF baseline'),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Keep all phones fixed and keep the scene as unchanged as possible during calibration. '
                'A person already present during calibration may become part of the baseline.',
              ),
            ] else if (snapshot.phase == DisturbancePhase.calibrating) ...[
              Text(
                'Calibrating ${(snapshot.baselineProgress * 100).round()}% — keep phones and scene still.',
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              LinearProgressIndicator(value: snapshot.baselineProgress),
            ] else ...[
              _OverallDisturbance(snapshot: snapshot),
              const SizedBox(height: 16),
              if (snapshot.links.isEmpty)
                const Text('Waiting for fresh BLE RSSI samples…')
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
                  label: const Text('Capture a new baseline'),
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
          'RF disturbance index: $score / 100',
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
    final shortId = link.peerNodeId.length <= 8
        ? link.peerNodeId
        : link.peerNodeId.substring(0, 8);
    final score = (link.score * 100).round();
    final ageSeconds = link.age.inMilliseconds / 1000;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Link → $shortId',
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
}

class _PhaseChip extends StatelessWidget {
  const _PhaseChip({required this.phase});

  final DisturbancePhase phase;

  @override
  Widget build(BuildContext context) {
    final text = switch (phase) {
      DisturbancePhase.idle => 'NOT CALIBRATED',
      DisturbancePhase.calibrating => 'CALIBRATING',
      DisturbancePhase.monitoring => 'MONITORING',
      DisturbancePhase.stale => 'RECALIBRATE',
    };
    return Chip(label: Text(text));
  }
}
