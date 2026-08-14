import 'package:flutter/material.dart';

import 'infrastructure/capabilities/sensor_capability_manager.dart';
import 'infrastructure/identity/persistent_node_identity.dart';
import 'presentation/universal_compatibility_dashboard.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final nodeId = await PersistentNodeIdentity().loadOrCreate();
  runApp(BodyFinderApp(nodeId: nodeId));
}

class BodyFinderApp extends StatelessWidget {
  const BodyFinderApp({
    super.key,
    this.manager,
    this.nodeId,
  });

  final SensorCapabilityManager? manager;
  final String? nodeId;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Body Finder',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: UniversalCompatibilityDashboard(
        manager: manager,
        nodeId: nodeId,
      ),
    );
  }
}
