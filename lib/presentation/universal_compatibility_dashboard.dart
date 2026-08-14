import 'package:flutter/material.dart';

import '../application/orchestration/portability_policy.dart';
import '../domain/capability/sensor_capability.dart';
import '../infrastructure/capabilities/sensor_capability_manager.dart';
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
  late Future<NodeCapabilities> _scan;

  @override
  void initState() {
    super.initState();
    _manager = widget.manager ?? SensorCapabilityManager();
    _scan = _manager.scan();
  }

  void _rescan() => setState(() => _scan = _manager.scan());

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
              ],
            );
          },
        ),
      );
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
