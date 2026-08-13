import 'package:flutter_test/flutter_test.dart';

import 'package:body_finder/main.dart';

void main() {
  testWidgets('shows scientific safety status on launch', (tester) async {
    await tester.pumpWidget(const BodyFinderApp());
    await tester.pumpAndSettle();

    expect(find.text('Body Finder'), findsOneWidget);
    expect(find.text('Experimental anomaly mapping'), findsOneWidget);
    expect(find.textContaining('not proof of presence or absence'), findsOneWidget);
  });
}
