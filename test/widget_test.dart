import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:body_finder/main.dart';

void main() {
  testWidgets('shows app shell while native capabilities load', (tester) async {
    await tester.pumpWidget(const BodyFinderApp());

    expect(find.text('Body Finder'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
