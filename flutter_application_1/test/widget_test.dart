import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_application_1/ui/fridgeguardian_demo.dart';

void main() {
  testWidgets('FridgeGuardian builds', (WidgetTester tester) async {
    await tester.pumpWidget(const FridgeGuardianApp());
    await tester.pumpAndSettle();
    expect(find.text('FridgeGuardian'), findsWidgets);
  });
}
