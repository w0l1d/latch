import 'package:flutter_test/flutter_test.dart';
import 'package:latch/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const LatchApp());
    await tester.pump();
    expect(find.text('Get started'), findsOneWidget);
  });
}
