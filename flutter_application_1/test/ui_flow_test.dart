import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_application_1/ui/fridgeguardian_demo.dart';

void main() {
  testWidgets('FridgeGuardian demo flow works end-to-end', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const FridgeGuardianApp());
    await tester.pumpAndSettle();

    expect(find.text('FridgeGuardian'), findsWidgets);

    await tester.tap(find.widgetWithText(FilledButton, 'Start Demo Flow'));
    await tester.pumpAndSettle();

    expect(find.text('Scan'), findsWidgets);

    await tester.tap(find.widgetWithText(FilledButton, 'Scan Whole Fridge (Demo)'));
    await tester.pump();
    expect(find.text('Analyzing fridge contents...'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(find.text('Inventory'), findsWidgets);
    expect(find.textContaining('Risk Summary:'), findsOneWidget);

    final Finder inventoryItemFinder = find.byWidgetPredicate(
      (Widget widget) =>
          widget is Text &&
          const <String>['Milk', 'Spinach', 'Tomatoes', 'Eggs'].contains(
            widget.data,
          ),
      description: 'inventory item name',
    );
    expect(inventoryItemFinder, findsAtLeastNWidgets(1));

    await tester.tap(find.widgetWithText(FilledButton, 'Continue to Suggestions'));
    await tester.pumpAndSettle();

    expect(find.text('Suggestions'), findsWidgets);
    expect(find.text('~15 min', skipOffstage: false), findsNWidgets(3));

    await tester.tap(find.widgetWithText(FilledButton, 'Open Dashboard'));
    await tester.pumpAndSettle();

    expect(find.text('Dashboard'), findsWidgets);
    expect(find.text('total_scans'), findsOneWidget);
    expect(find.text('total_items_saved'), findsOneWidget);
    expect(find.text('co2e_avoided_kg'), findsOneWidget);
  });
}
