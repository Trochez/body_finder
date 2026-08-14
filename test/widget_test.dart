import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:body_finder/infrastructure/capabilities/sensor_capability_manager.dart';
import 'package:body_finder/main.dart';

void main() {
  testWidgets('shows app shell while native capabilities load', (tester) async {
    final pending = Completer<Map<Object?, Object?>>();
    final manager = SensorCapabilityManager(probe: () => pending.future);

    await tester.pumpWidget(BodyFinderApp(manager: manager));

    expect(find.text('Body Finder'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
