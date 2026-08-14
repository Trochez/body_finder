import 'package:flutter/material.dart';

import 'infrastructure/capabilities/sensor_capability_manager.dart';
import 'presentation/universal_compatibility_dashboard.dart';

void main() {
  runApp(const BodyFinderApp());
}

class BodyFinderApp extends StatelessWidget {
  const BodyFinderApp({super.key, this.manager});

  final SensorCapabilityManager? manager;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Body Finder',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: UniversalCompatibilityDashboard(manager: manager),
    );
  }
}
