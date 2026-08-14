import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../application/geometry/polygon.dart';
import '../application/session/peer_registry.dart';
import '../domain/geometry/vec2.dart';
import '../infrastructure/network/lan_peer_discovery.dart';

class NodeGeometryPanel extends StatelessWidget {
  const NodeGeometryPanel({
    super.key,
    required this.discovery,
    required this.snapshot,
  });

  final LanPeerDiscovery discovery;
  final PeerDiscoverySnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final positioned = snapshot.peers
        .where((peer) => peer.position != null)
        .toList(growable: false);
    final unresolved = snapshot.unresolvedNodeIds.length;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Automatic relative positioning',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 6),
            const Text(
              'No manual XY entry is required. Body Finder derives a shared meter-scale frame only from real range observations exposed by participating devices.',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                Chip(label: Text('${snapshot.rangeObservationCount} range edges')),
                Chip(label: Text('${positioned.length}/${snapshot.nodeCount} positioned')),
                Chip(
                  label: Text(
                    snapshot.has2DFrame ? '2D FRAME READY' : '$unresolved UNRESOLVED',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (snapshot.has2DFrame)
              const Text(
                'The coordinate frame is relative: origin and rotation are selected deterministically from the active range graph. Accuracy depends on the ranging sources and geometry.',
              )
            else
              const Text(
                'Waiting for enough independent distance observations. LAN heartbeat timing is not converted into physical distance. UWB, Wi-Fi RTT, BLE RSSI, or a compatible external ranging source must provide the required edges.',
              ),
            const SizedBox(height: 12),
            if (positioned.isNotEmpty)
              SizedBox(
                height: 280,
                width: double.infinity,
                child: CustomPaint(
                  painter: _GeometryPainter(
                    peers: positioned,
                    localNodeId: snapshot.localNodeId,
                    coordinatorId: snapshot.coordinatorId,
                  ),
                ),
              )
            else
              const Text('No defensible metric position is available yet.'),
            const SizedBox(height: 8),
            ...snapshot.peers.map(
              (peer) => Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '${_shortId(peer.id)} · ${peer.platform} · ${_positionText(peer)}',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _positionText(PeerRecord peer) {
    final position = peer.position;
    if (position == null) return 'position unresolved';
    final sigma = peer.positionSigmaMeters;
    final uncertainty = sigma == null || !sigma.isFinite
        ? 'uncertainty pending'
        : '±${sigma.toStringAsFixed(2)} m';
    return '(${position.x.toStringAsFixed(2)}, ${position.y.toStringAsFixed(2)}) m · $uncertainty';
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
        final first = project(boundary.first);
        final path = Path()..moveTo(first.dx, first.dy);
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
      final sigma = peer.positionSigmaMeters;
      if (sigma != null && sigma.isFinite && sigma > 0) {
        final scaleX = drawableWidth / math.max(0.01, maxX - minX);
        final radius = math.min(45.0, math.max(4.0, sigma * scaleX));
        canvas.drawCircle(
          p,
          radius,
          Paint()
            ..color = Colors.teal.withValues(alpha: 0.08)
            ..style = PaintingStyle.fill,
        );
      }
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
