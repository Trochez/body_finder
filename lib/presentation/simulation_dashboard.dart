import 'package:flutter/material.dart';

import '../application/simulation/demo_scenario.dart';

class SimulationDashboard extends StatelessWidget {
  const SimulationDashboard({super.key});

  @override
  Widget build(BuildContext context) {
    const scenario = DemoScenario.room;
    return Scaffold(
      appBar: AppBar(title: const Text('Simulation')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'SIMULATION ONLY — synthetic markers are not sensor detections and do not prove presence or absence.',
          ),
          const SizedBox(height: 16),
          Text('Phones: ${scenario.phonePositions.length}'),
          Text('Synthetic markers: ${scenario.syntheticMarkers.length}'),
          const SizedBox(height: 16),
          ...scenario.phonePositions.indexed.map(
            (entry) => ListTile(
              leading: const Icon(Icons.phone_android),
              title: Text('Phone ${entry.$1 + 1}'),
              subtitle: Text('${entry.$2.x.toStringAsFixed(1)} m, ${entry.$2.y.toStringAsFixed(1)} m'),
            ),
          ),
          const Divider(),
          ...scenario.syntheticMarkers.indexed.map(
            (entry) => ListTile(
              leading: const Icon(Icons.location_searching),
              title: Text('Synthetic marker ${entry.$1 + 1}'),
              subtitle: Text('${entry.$2.x.toStringAsFixed(1)} m, ${entry.$2.y.toStringAsFixed(1)} m'),
            ),
          ),
        ],
      ),
    );
  }
}
