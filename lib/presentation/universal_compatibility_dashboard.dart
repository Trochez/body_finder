import 'dart:async';

import 'package:flutter/material.dart';

import '../application/diagnostics/session_validation_recorder.dart';
import '../application/orchestration/portability_policy.dart';
import '../application/sensing/rssi_disturbance_tracker.dart';
import '../domain/capability/sensor_capability.dart';
import '../infrastructure/capabilities/sensor_capability_manager.dart';
import '../infrastructure/network/lan_peer_discovery.dart';
import '../infrastructure/network/session_transport_factory.dart';
import '../infrastructure/ranging/ble_range_adapter.dart';
import 'capability_dashboard.dart';
import 'experimental_disturbance_panel.dart';
import 'node_geometry_panel.dart';
import 'validation_report_panel.dart';

class UniversalCompatibilityDashboard extends StatefulWidget {
  const UniversalCompatibilityDashboard({
    super.key,
    this.manager,
    this.nodeId,
  });

  final SensorCapabilityManager? manager;
  final String? nodeId;

  @override
  State<UniversalCompatibilityDashboard> createState() =>
      _UniversalCompatibilityDashboardState();
}

class _UniversalCompatibilityDashboardState
    extends State<UniversalCompatibilityDashboard> {
  late final SensorCapabilityManager _manager;
  late final LanPeerDiscovery _discovery;
  late final BleRangeAdapter _bleRanging;
  late Future<NodeCapabilities> _scan;

  final SessionValidationRecorder _validationRecorder =
      SessionValidationRecorder();
  final RssiDisturbanceTracker _disturbanceTracker = RssiDisturbanceTracker();

  PeerDiscoverySnapshot? _peerSnapshot;
  SessionValidationReport? _lastValidationReport;
  bool _sessionStarting = false;
  bool _sessionRunning = false;
  bool _mobileSensingReadyLatched = false;
  Set<String> _mobileSensingPeerIds = const {};
  String? _sessionError;
  String _bleRangingStatus = 'idle';

  @override
  void initState() {
    super.initState();
    _manager = widget.manager ?? SensorCapabilityManager();
    _scan = _manager.scan();
    final nodeId = widget.nodeId;
    _discovery = LanPeerDiscovery(
      onChanged: _onPeersChanged,
      nodeId: nodeId,
      transports: nodeId == null
          ? null
          : [
              createDefaultSessionTransport(
                nodeId: nodeId,
                lanPort: LanPeerDiscovery.port,
              ),
            ],
    );
    _bleRanging = BleRangeAdapter();
  }

  @override
  void dispose() {
    unawaited(_bleRanging.stop());
    unawaited(_discovery.stop());
    super.dispose();
  }

  void _rescan() => setState(() => _scan = _manager.scan());

  void _recordSnapshot(PeerDiscoverySnapshot snapshot) {
    _validationRecorder.recordTopology(
      nodeIds: snapshot.peers.map((peer) => peer.id),
      metricNodeCount: snapshot.positionedNodeCount,
      rangeEdgeCount: snapshot.rangeObservationCount,
    );
    _validationRecorder.recordTransports(_discovery.activeTransportIds);
    _validationRecorder.recordTransportDiagnostics(
      pathStatuses: _discovery.transportPathStatuses,
      relayedMessageCount: _discovery.relayedMessageCount,
      duplicateMessageCount: _discovery.duplicateMessageCount,
    );
  }

  Iterable<String> _remotePeerIds(PeerDiscoverySnapshot snapshot) => snapshot.peers
      .where((peer) => peer.id != snapshot.localNodeId)
      .map((peer) => peer.id);

  void _onPeersChanged(PeerDiscoverySnapshot snapshot) {
    _recordSnapshot(snapshot);
    final remotePeers = _remotePeerIds(snapshot).toSet();

    // RF sensing only needs a known three-phone membership plus RSSI samples.
    // Do not tie calibration availability to the instantaneous metric solver:
    // BLE-derived geometry can briefly become unresolved while the same phones
    // and links remain valid for baseline/disturbance monitoring.
    if (snapshot.nodeCount >= 3 && remotePeers.length >= 2) {
      _mobileSensingReadyLatched = true;
      _mobileSensingPeerIds = Set.unmodifiable(remotePeers);
    }

    _disturbanceTracker.reconcilePeers(remotePeers);
    if (!mounted) return;
    setState(() => _peerSnapshot = snapshot);
  }

  void _onBleStatus(String status) {
    if (!mounted) return;
    setState(() => _bleRangingStatus = status);
  }

  Future<void> _startAutomaticRanging() async {
    _onBleStatus('starting');
    await _bleRanging.start(
      nodeId: _discovery.nodeId,
      onStatus: _onBleStatus,
      onRange: (update) {
        _validationRecorder.recordPhysicalRange(
          peerNodeId: update.peerNodeId,
          source: BleRangeAdapter.source.name,
          distanceMeters: update.distanceMeters,
          sigmaMeters: update.sigmaMeters,
          rssiDbm: update.rssiDbm,
        );
        _disturbanceTracker.addSample(
          peerNodeId: update.peerNodeId,
          rssiDbm: update.rssiDbm,
        );
        _discovery.publishLocalRange(
          peerNodeId: update.peerNodeId,
          distanceMeters: update.distanceMeters,
          sigmaMeters: update.sigmaMeters,
          source: BleRangeAdapter.source,
        );
        if (mounted) setState(() {});
      },
    );
  }

  void _startDisturbanceCalibration() {
    final snapshot = _peerSnapshot;
    if (snapshot == null) return;
    final peers = _mobileSensingPeerIds.length >= 2
        ? _mobileSensingPeerIds
        : _remotePeerIds(snapshot).toSet();
    if (peers.length < 2) return;
    _disturbanceTracker.startCalibration(peers);
    setState(() {});
  }

  Future<void> _startSession() async {
    if (_sessionStarting || _sessionRunning) return;
    _validationRecorder.reset();
    _disturbanceTracker.reset();
    _mobileSensingReadyLatched = false;
    _mobileSensingPeerIds = const {};
    setState(() {
      _sessionStarting = true;
      _sessionError = null;
      _lastValidationReport = null;
    });

    try {
      await _discovery.start();
      if (!mounted) return;
      final snapshot = _discovery.snapshot;
      _recordSnapshot(snapshot);
      setState(() {
        _sessionStarting = false;
        _sessionRunning = true;
        _peerSnapshot = snapshot;
      });
      unawaited(_startAutomaticRanging());
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _sessionStarting = false;
        _sessionRunning = false;
        _sessionError = error.toString();
      });
    }
  }

  Future<void> _stopSession() async {
    final finalReport = _validationRecorder.report;
    await _bleRanging.stop();
    await _discovery.stop();
    _disturbanceTracker.reset();
    if (!mounted) return;
    setState(() {
      _sessionRunning = false;
      _peerSnapshot = null;
      _sessionError = null;
      _bleRangingStatus = 'idle';
      _mobileSensingReadyLatched = false;
      _mobileSensingPeerIds = const {};
      _lastValidationReport = finalReport;
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Body Finder'),
          actions: [
            IconButton(
              tooltip: 'Rescan device',
              onPressed: _rescan,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: FutureBuilder<NodeCapabilities>(
          future: _scan,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return const _CompatibilityMessage(
                title: 'Compatibility scan unavailable',
                message:
                    'The app can still launch. Retry the scan or continue with supported session/UI functions.',
              );
            }

            final node = snapshot.data!;
            final profile = selectOperatingProfile(node);
            final exposed = node.capabilities
                .where((value) => value.hardwareAvailable && value.apiAvailable)
                .length;
            final ready = node.capabilities
                .where((value) => value.measurementAvailable)
                .length;
            final setupNeeded = ready < exposed;

            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  'Universal device compatibility',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                const Text(
                  'No premium sensor is required to participate. Body Finder automatically uses the capabilities exposed by each device.',
                ),
                const SizedBox(height: 16),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.devices),
                    title: Text('Hardware tier: ${profile.label}'),
                    subtitle: Text(
                      '${profile.description}\n$ready of $exposed exposed capabilities are currently ready.',
                    ),
                    isThreeLine: true,
                    trailing: Text(setupNeeded ? 'SETUP' : 'READY'),
                  ),
                ),
                const SizedBox(height: 8),
                Text('${node.platform} ${node.platformVersion}'),
                Text('$exposed exposed capabilities · $ready ready now'),
                if (setupNeeded) ...[
                  const SizedBox(height: 8),
                  const Text(
                    'Some capabilities require permission or session setup before they can contribute measurements.',
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => CapabilityDashboard(manager: _manager),
                    ),
                  ),
                  icon: const Icon(Icons.sensors),
                  label: const Text('View sensor details'),
                ),
                const SizedBox(height: 24),
                Text(
                  'Nearby node session',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Session/control transport and physical sensing are separate. Body Finder can combine BLE control and LAN/UDP paths when available; Wi-Fi LAN and Ethernet still contribute zero physical sensing evidence.',
                ),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              _sessionRunning ? Icons.hub : Icons.hub_outlined,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                _sessionRunning
                                    ? 'Session active'
                                    : 'Session stopped',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                            Text(
                              _sessionRunning
                                  ? '${_peerSnapshot?.nodeCount ?? 1} NODE${(_peerSnapshot?.nodeCount ?? 1) == 1 ? '' : 'S'}'
                                  : 'OFF',
                            ),
                          ],
                        ),
                        if (_sessionRunning && _peerSnapshot != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            'This node: ${_shortId(_peerSnapshot!.localNodeId)}',
                          ),
                          Text(
                            'Coordinator: ${_shortId(_peerSnapshot!.coordinatorId)}',
                          ),
                          Text(
                            'Active transport(s): ${_discovery.activeTransportIds.join(', ')} · transport only',
                          ),
                          Text(
                            'Transport status: ${_formatTransportStatuses(_discovery.transportPathStatuses)}',
                          ),
                          Text('BLE automatic ranging: $_bleRangingStatus'),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: _peerSnapshot!.peers
                                .map(
                                  (peer) => Chip(
                                    avatar: Icon(
                                      peer.id == _peerSnapshot!.coordinatorId
                                          ? Icons.star
                                          : peer.platform == 'android'
                                              ? Icons.smartphone
                                              : Icons.computer,
                                      size: 18,
                                    ),
                                    label: Text(
                                      '${_shortId(peer.id)} · ${peer.platform}',
                                    ),
                                  ),
                                )
                                .toList(growable: false),
                          ),
                        ],
                        if (_sessionError != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            'Could not start local session: $_sessionError',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ],
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          child: _sessionRunning
                              ? OutlinedButton.icon(
                                  onPressed: _stopSession,
                                  icon: const Icon(Icons.stop_circle_outlined),
                                  label: const Text('Stop nearby session'),
                                )
                              : FilledButton.icon(
                                  onPressed:
                                      _sessionStarting ? null : _startSession,
                                  icon: _sessionStarting
                                      ? const SizedBox.square(
                                          dimension: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Icon(Icons.play_arrow),
                                  label: Text(
                                    _sessionStarting
                                        ? 'Starting…'
                                        : 'Start nearby session',
                                  ),
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_sessionRunning && _peerSnapshot != null) ...[
                  const SizedBox(height: 12),
                  NodeGeometryPanel(
                    discovery: _discovery,
                    snapshot: _peerSnapshot!,
                  ),
                  const SizedBox(height: 12),
                  ExperimentalDisturbancePanel(
                    snapshot: _disturbanceTracker.snapshot(),
                    sensingReady: _mobileSensingReadyLatched,
                    onCalibrate: _mobileSensingReadyLatched
                        ? _startDisturbanceCalibration
                        : null,
                  ),
                  const SizedBox(height: 12),
                  ValidationReportPanel(report: _validationRecorder.report),
                ] else if (_lastValidationReport != null) ...[
                  const SizedBox(height: 12),
                  ValidationReportPanel(
                    report: _lastValidationReport!,
                    live: false,
                  ),
                ],
              ],
            );
          },
        ),
      );

  static String _shortId(String? value) {
    if (value == null || value.isEmpty) return 'none';
    return value.length <= 8 ? value : value.substring(0, 8);
  }

  static String _formatTransportStatuses(Map<String, String> statuses) {
    if (statuses.isEmpty) return 'none';
    return statuses.entries
        .map((entry) => '${entry.key}=${entry.value}')
        .join(', ');
  }
}

class _CompatibilityMessage extends StatelessWidget {
  const _CompatibilityMessage({required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(message),
          ],
        ),
      );
}
