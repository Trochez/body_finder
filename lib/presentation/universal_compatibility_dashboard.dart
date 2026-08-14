import 'package:flutter/material.dart';

import '../application/orchestration/portability_policy.dart';
import '../domain/capability/sensor_capability.dart';
import '../infrastructure/capabilities/sensor_capability_manager.dart';
import '../infrastructure/network/lan_peer_discovery.dart';
import 'capability_dashboard.dart';

class UniversalCompatibilityDashboard extends StatefulWidget {
  const UniversalCompatibilityDashboard({super.key, this.manager});

  final SensorCapabilityManager? manager;

  @override
  State<UniversalCompatibilityDashboard> createState() =>
      _UniversalCompatibilityDashboardState();
}

class _UniversalCompatibilityDashboardState
    extends State<UniversalCompatibilityDashboard> {
  late final SensorCapabilityManager _manager;
  late final LanPeerDiscovery _discovery;
  late Future<NodeCapabilities> _scan;

  PeerDiscoverySnapshot? _peerSnapshot;
  bool _sessionStarting = false;
  bool _sessionRunning = false;
  String? _sessionError;

  @override
  void initState() {
    super.initState();
    _manager = widget.manager ?? SensorCapabilityManager();
    _scan = _manager.scan();
    _discovery = LanPeerDiscovery(onChanged: _onPeersChanged);
  }

  @override
  void dispose() {
    _discovery.stop();
    super.dispose();
  }

  void _rescan() => setState(() => _scan = _manager.scan());

  void _onPeersChanged(PeerDiscoverySnapshot snapshot) {
    if (!mounted) return;
    setState(() => _peerSnapshot = snapshot);
  }

  Future<void> _startSession() async {
    if (_sessionStarting || _sessionRunning) return;
    setState(() {
      _sessionStarting = true;
      _sessionError = null;
    });

    try {
      await _discovery.start();
      if (!mounted) return;
      setState(() {
        _sessionStarting = false;
        _sessionRunning = true;
        _peerSnapshot = _discovery.snapshot;
      });
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
    await _discovery.stop();
    if (!mounted) return;
    setState(() {
      _sessionRunning = false;
      _peerSnapshot = null;
      _sessionError = null;
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Body Finder'),
          actions: [
            IconButton(
              tooltip: 'Rescan phone',
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
                  'Universal phone compatibility',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                const Text(
                  'No premium sensor is required to run Body Finder. The app automatically uses the capabilities exposed by this phone.',
                ),
                const SizedBox(height: 16),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.smartphone),
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
                  'Nearby phone session',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                const Text(
                  'First transport: put every test phone on the same Wi-Fi network. Body Finder will exchange local-only discovery beacons and remove phones automatically when their heartbeat disappears.',
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
                                  ? '${_peerSnapshot?.phoneCount ?? 1} PHONE${(_peerSnapshot?.phoneCount ?? 1) == 1 ? '' : 'S'}'
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
                                          : Icons.smartphone,
                                      size: 18,
                                    ),
                                    label: Text(_shortId(peer.id)),
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
              ],
            );
          },
        ),
      );

  static String _shortId(String? value) {
    if (value == null || value.isEmpty) return 'none';
    return value.length <= 8 ? value : value.substring(0, 8);
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
