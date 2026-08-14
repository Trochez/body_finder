import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../application/geometry/polygon.dart';
import '../application/session/peer_registry.dart';
import '../domain/geometry/vec2.dart';
import '../infrastructure/network/lan_peer_discovery.dart';

class NodeGeometryPanel extends StatefulWidget {
  const NodeGeometryPanel({
    super.key,
    required this.discovery,
    required this.snapshot,
  });

  final LanPeerDiscovery discovery;
  final PeerDiscoverySnapshot snapshot;

  @override
  State<NodeGeometryPanel> createState() => _NodeGeometryPanelState();
}

class _NodeGeometryPanelState extends State<NodeGeometryPanel> {
  final _xController = TextEditingController();
  final _yController = TextEditingController();
  String? _inputError;

  @override
  void dispose() {
    _xController.dispose();
    _yController.dispose();
    super.dispose();
  }

  void _applyPosition() {
    final x = double.tryParse(_xController.text.trim().replaceAll(',', '.'));
    final y = double.tryParse(_yController.text.trim().replaceAll(',', '.'));
    if (x == null || y == null || !x.isFinite || !y.isFinite) {
      setState(() => _inputError = 'Enter valid X and Y values in meters.');
      return;
    }
    widget.discovery.updateLocalPosition(Vec2(x, y));
    setState(() => _inputError = null);
  }

  void _clearPosition() {
    widget.discovery.updateLocalPosition(null);
    _xController.clear();
    _yController.clear();
    setState(() => _inputError = null);
  }

  @override
  Widget build(BuildContext context) {
    final positioned = widget.snapshot.peers
        .where((peer) => peer.position != null)
        .toList(growable: false);
    final local = widget.snapshot.peers
        .where((peer) => peer.id == widget.snapshot.localNodeId)
        .firstOrNull;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Shared XY geometry', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            const Text(
              'For this validation step, enter the measured position of this device in meters. Each node broadcasts only its own coordinate.',
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _xController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                    decoration: const InputDecoration(
                      labelText: 'My X (m)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _yController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                    decoration: const InputDecoration(
                      labelText: 'My Y (m)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            if (_inputError != null) ...[
              const SizedBox(height: 8),
              Text(
                _inputError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _applyPosition,
                    icon: const Icon(Icons.place),
                    label: const Text('Broadcast my position'),
                  ),
                ),
                if (local?.position != null) ...[
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Clear my position',
                    onPressed: _clearPosition,
                    icon: const Icon(Icons.clear),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            Text(
              '${positioned.length} of ${widget.snapshot.nodeCount} nodes positioned'
              '${positioned.length >= 3 ? ' · 2D perimeter ready' : ' · need ${math.max(0, 3 - positioned.length)} more for a 2D perimeter'}',
            ),
            const SizedBox(height: 12),
            if (positioned.isNotEmpty)
              SizedBox(
                height: 280,
                width: double.infinity,
                child: CustomPaint(
                  painter: _GeometryPainter(
                    peers: positioned,
                    localNodeId: widget.snapshot.localNodeId,
                    coordinatorId: widget.snapshot.coordinatorId,
                  ),
                ),
              )
            else
              const Text('No node has published an XY position yet.'),
            const SizedBox(height: 8),
            ...widget.snapshot.peers.map(
              (peer) => Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '${_shortId(peer.id)} · ${peer.platform} · '
                  '${peer.position == null ? 'position pending' : '(${peer.position!.x.toStringAsFixed(2)}, ${peer.position!.y.toStringAsFixed(2)}) m'}',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _shortId(String value) =>
      value.length <= 8 ? value : value.substring(0, 8);
}

class _GeometryPainter extends CustomPainter {
  _GeometryPainter({
    required this.peers,
    required this.localNodeId,
    required this.coordinatorId,
  });

  final List<PeerRecord> peers;
  final String localNodeId;
  final String? coordinatorId;

  @override
  void paint(Canvas canvas, Size size) {
    final points = peers.map((peer) => peer.position!).toList(growable: false);
    var minX = points.map((p) => p.x).reduce(math.min);
    var maxX = points.map((p) => p.x).reduce(math.max);
    var minY = points.map((p) => p.y).reduce(math.min);
    var maxY = points.map((p) => p.y).reduce(math.max);

    if ((maxX - minX).abs() < 0.01) {
      minX -= 1;
      maxX += 1;
    }
    if ((maxY - minY).abs() < 0.01) {
      minY -= 1;
      maxY += 1;
    }

    final padX = math.max(0.5, (maxX - minX) * 0.15);
    final padY = math.max(0.5, (maxY - minY) * 0.15);
    minX -= padX;
    maxX += padX;
    minY -= padY;
    maxY += padY;

    const margin = 28.0;
    final drawableWidth = math.max(1.0, size.width - margin * 2);
    final drawableHeight = math.max(1.0, size.height - margin * 2);

    Offset project(Vec2 point) {
      final nx = (point.x - minX) / (maxX - minX);
      final ny = (point.y - minY) / (maxY - minY);
      return Offset(
        margin + nx * drawableWidth,
        size.height - margin - ny * drawableHeight,
      );
    }

    final gridPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.10)
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final x = margin + drawableWidth * i / 4;
      final y = margin + drawableHeight * i / 4;
      canvas.drawLine(Offset(x, margin), Offset(x, size.height - margin), gridPaint);
      canvas.drawLine(Offset(margin, y), Offset(size.width - margin, y), gridPaint);
    }

    if (points.length >= 3) {
      final boundary = convexBoundary(points).vertices;
      if (boundary.length >= 3) {
        final path = Path()..moveTo(project(boundary.first).dx, project(boundary.first).dy);
        for (final vertex in boundary.skip(1)) {
          final p = project(vertex);
          path.lineTo(p.dx, p.dy);
        }
        path.close();
        canvas.drawPath(
          path,
          Paint()
            ..color = Colors.teal.withValues(alpha: 0.12)
            ..style = PaintingStyle.fill,
        );
        canvas.drawPath(
          path,
          Paint()
            ..color = Colors.teal
            ..strokeWidth = 2
            ..style = PaintingStyle.stroke,
        );
      }
    }

    for (final peer in peers) {
      final p = project(peer.position!);
      final isLocal = peer.id == localNodeId;
      final isCoordinator = peer.id == coordinatorId;
      canvas.drawCircle(
        p,
        isLocal ? 9 : 7,
        Paint()..color = isCoordinator ? Colors.amber.shade800 : Colors.teal.shade700,
      );
      final label = '${_shortId(peer.id)}\n${peer.position!.x.toStringAsFixed(1)}, ${peer.position!.y.toStringAsFixed(1)} m';
      final textPainter = TextPainter(
        text: TextSpan(
          text: label,
          style: const TextStyle(color: Colors.black87, fontSize: 11),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 120);
      textPainter.paint(canvas, p + const Offset(10, -8));
    }
  }

  static String _shortId(String value) =>
      value.length <= 8 ? value : value.substring(0, 8);

  @override
  bool shouldRepaint(covariant _GeometryPainter oldDelegate) =>
      oldDelegate.peers != peers ||
      oldDelegate.localNodeId != localNodeId ||
      oldDelegate.coordinatorId != coordinatorId;
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
