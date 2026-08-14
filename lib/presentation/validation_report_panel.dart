import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../application/diagnostics/session_validation_recorder.dart';

class ValidationReportPanel extends StatelessWidget {
  const ValidationReportPanel({
    super.key,
    required this.report,
    this.live = true,
  });

  final SessionValidationReport report;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final ranges = report.latestRangesByPeer.values.toList(growable: false)
      ..sort((left, right) => left.peerNodeId.compareTo(right.peerNodeId));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.science_outlined),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    live ? 'Live validation observations' : 'Last validation observations',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: 'Copy validation report',
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(text: report.toPlainText()),
                    );
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Validation report copied')),
                    );
                  },
                  icon: const Icon(Icons.copy_outlined),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              'Observed measurements only. Network transports do not count as physical sensing evidence.',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                Chip(label: Text('${report.maxNodeCount} max nodes')),
                Chip(label: Text('${report.maxRangeEdgeCount} max range edges')),
                Chip(label: Text('${report.maxMetricNodeCount} max metric nodes')),
                Chip(label: Text('${report.rangeSampleCount} physical samples')),
              ],
            ),
            if (ranges.isNotEmpty) ...[
              const SizedBox(height: 12),
              ...ranges.map((range) => _RangeRow(range: range)),
            ],
            const SizedBox(height: 12),
            SelectableText(
              report.toPlainText(),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _RangeRow extends StatelessWidget {
  const _RangeRow({required this.range});

  final PhysicalRangeTelemetry range;

  @override
  Widget build(BuildContext context) {
    final ageMicros = DateTime.now().microsecondsSinceEpoch - range.observedAtMicros;
    final ageSeconds = ageMicros <= 0 ? 0.0 : ageMicros / 1000000.0;
    final rssi = range.rssiDbm == null
        ? 'RSSI n/a'
        : 'RSSI ${range.rssiDbm!.toStringAsFixed(1)} dBm';
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        '${_shortId(range.peerNodeId)} · ${range.source} · '
        '${range.distanceMeters.toStringAsFixed(2)} m · '
        '±${range.sigmaMeters.toStringAsFixed(2)} m · $rssi · '
        '${ageSeconds.toStringAsFixed(1)} s old',
      ),
    );
  }

  static String _shortId(String value) =>
      value.length <= 8 ? value : value.substring(0, 8);
}
