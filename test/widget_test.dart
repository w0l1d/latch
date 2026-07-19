import 'package:flutter_test/flutter_test.dart';
import 'package:latch/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const LatchApp());
    // The router redirect awaits SharedPreferences, so the first route
    // resolves asynchronously — pump a few bounded frames.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (find.text('Get started').evaluate().isNotEmpty) break;
    }
    expect(find.text('Get started'), findsOneWidget);
  });
}
