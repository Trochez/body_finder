import 'package:flutter/material.dart';

import 'safety_gate.dart';

void main() {
  runApp(const BodyFinderApp());
}

class BodyFinderApp extends StatelessWidget {
  const BodyFinderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Body Finder',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal)),
      home: const BodyFinderHomePage(),
    );
  }
}

class BodyFinderHomePage extends StatelessWidget {
  const BodyFinderHomePage({super.key});

  static final gate = SafetyGate(
    evidence: EvidenceLabel.theoretical,
    anomalyScore: 0,
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Body Finder')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Experimental anomaly mapping',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),
            Text(gate.message),
            const SizedBox(height: 24),
            const Text(
              'Use only with trained teams and independent search procedures.',
            ),
          ],
        ),
      ),
    );
  }
}
