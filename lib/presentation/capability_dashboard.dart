import 'package:flutter/material.dart';

import '../domain/capability/sensor_capability.dart';
import '../infrastructure/capabilities/sensor_capability_manager.dart';
import '../safety_gate.dart';

class CapabilityDashboard extends StatefulWidget {
  const CapabilityDashboard({super.key, this.manager});

  final SensorCapabilityManager? manager;

  @override
  State<CapabilityDashboard> createState() => _CapabilityDashboardState();
}

class _CapabilityDashboardState extends State<CapabilityDashboard> {
  late final SensorCapabilityManager _manager;
  late Future<NodeCapabilities> _scan;

  static final _safetyGate = SafetyGate(
    evidence: EvidenceLabel.theoretical,
    anomalyScore: 0,
  );

  @override
  void initState() {
    super.initState();
    _manager = widget.manager ?? SensorCapabilityManager();
    _scan = _manager.scan();
  }

  void _rescan() => setState(() => _scan = _manager.scan());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Body Finder'),
        actions: [
          IconButton(
            tooltip: 'Rescan capabilities',
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
            return _MessagePanel(
              title: 'Capability scan failed',
              message: snapshot.error.toString(),
            );
          }
          final node = snapshot.data!;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'Experimental anomaly mapping',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(_safetyGate.message),
              const SizedBox(height: 4),
              const Text(
                'A sensor is usable only when hardware, OS API, permission, and measurement state allow it.',
              ),
              const SizedBox(height: 20),
              Text(
                '${node.platform} ${node.platformVersion}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              if (node.capabilities.isEmpty)
                const _MessagePanel(
                  title: 'No native capability provider',
                  message: 'This platform is outside the Android/iOS sensing MVP.',
                )
              else
                ...node.capabilities.map((value) => _CapabilityTile(value)),
            ],
          );
        },
      ),
    );
  }
}

class _CapabilityTile extends StatelessWidget {
  const _CapabilityTile(this.capability);

  final SensorCapability capability;

  @override
  Widget build(BuildContext context) {
    final usable = capability.measurementAvailable;
    return Card(
      child: ListTile(
        leading: Icon(usable ? Icons.sensors : Icons.sensors_off),
        title: Text(_label(capability.type)),
        subtitle: Text(
          'hardware=${capability.hardwareAvailable} · api=${capability.apiAvailable} · '
          'permission=${capability.permissionState.name} · '
          'quality=${(capability.estimatedQuality * 100).round()}%'
          '${capability.restrictionReason == null ? '' : '\n${capability.restrictionReason}'}',
        ),
        trailing: Text(usable ? 'READY' : 'LIMITED'),
      ),
    );
  }

  String _label(SensorType type) => switch (type) {
        SensorType.bluetoothLowEnergy => 'Bluetooth LE / RSSI',
        SensorType.wifi => 'Wi-Fi',
        SensorType.wifiRtt => 'Wi-Fi RTT / FTM',
        SensorType.wifiCsi => 'Wi-Fi CSI',
        SensorType.uwbRanging => 'UWB ranging',
        SensorType.rawUwb => 'Raw UWB samples',
        SensorType.accelerometer => 'Accelerometer',
        SensorType.gyroscope => 'Gyroscope',
        SensorType.magnetometer => 'Magnetometer',
        SensorType.barometer => 'Barometer',
        SensorType.gnss => 'GNSS / Location',
        SensorType.microphone => 'Microphone',
      };
}

class _MessagePanel extends StatelessWidget {
  const _MessagePanel({required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(message),
          ],
        ),
      );
}
