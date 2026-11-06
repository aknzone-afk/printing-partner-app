import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:printing_partner/main.dart';

void main() {
  testWidgets('Welcome screen renders', (WidgetTester tester) async {
    await tester.pumpWidget(const PrintingPartnerApp());
    await tester.pumpAndSettle();
    expect(find.text('Printing Partner'), findsOneWidget);
    expect(find.text('Get Started'), findsOneWidget);
  });
}
