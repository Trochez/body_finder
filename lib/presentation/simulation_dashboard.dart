import 'package:flutter/material.dart';

class SimulationDashboard extends StatelessWidget {
  const SimulationDashboard({super.key});

  @override
  Widget build(BuildContext context) => const Scaffold(
        body: Center(
          child: Text('Simulation mode: synthetic data only.'),
        ),
      );
}
