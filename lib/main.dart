import 'package:flutter/material.dart';

import 'presentation/capability_dashboard.dart';

void main() {
  runApp(const BodyFinderApp());
}

class BodyFinderApp extends StatelessWidget {
  const BodyFinderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Body Finder',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const CapabilityDashboard(),
    );
  }
}
