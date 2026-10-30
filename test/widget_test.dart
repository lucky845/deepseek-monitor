import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseek_monitor/main.dart';

void main() {
  testWidgets('App builds', (WidgetTester tester) async {
    await tester.pumpWidget(const DeepSeekMonitorApp());
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
