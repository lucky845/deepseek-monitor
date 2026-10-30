import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:deepseek_monitor/providers/glass_provider.dart';
import 'package:deepseek_monitor/widgets/glass_card.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('the glass thickness setting', () {
    test('stays inside the band it advertises, and names how thick it is',
        () async {
      final glass = GlassProvider();
      await glass.load();
      expect(glass.strength, 1.0);
      expect(glass.label, '标准');

      await glass.setStrength(9);
      expect(glass.strength, kGlassMax);
      expect(glass.label, '厚重');

      await glass.setStrength(-4);
      expect(glass.strength, kGlassMin);
      expect(glass.label, '通透');
    });

    test('remembers the choice, and distrusts a stored value from elsewhere',
        () async {
      final glass = GlassProvider();
      await glass.setStrength(0.6);

      final reopened = GlassProvider();
      await reopened.load();
      expect(reopened.strength, closeTo(0.6, 1e-9));

      // A value written by some older build, or edited by hand: still clamped.
      SharedPreferences.setMockInitialValues({'glass_strength': 99.0});
      final wild = GlassProvider();
      await wild.load();
      expect(wild.strength, kGlassMax);
    });
  });

  testWidgets('dragging the slider thickens the panes and writes it down',
      (tester) async {
    final glass = GlassProvider();
    await glass.load();
    await tester.pumpWidget(GlassScope(
      notifier: glass,
      child: const MaterialApp(home: Scaffold(body: GlassCard())),
    ));
    await tester.pump();
    expect(tester.widget<Slider>(find.byType(Slider)).value, 1.0);

    await tester.drag(find.byType(Slider), const Offset(300, 0));
    await tester.pump();

    expect(glass.strength, greaterThan(1.1));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('glass_strength'), closeTo(glass.strength, 1e-9));
  });

  testWidgets('with no scope the card still draws, just read-only',
      (tester) async {
    await tester
        .pumpWidget(const MaterialApp(home: Scaffold(body: GlassCard())));
    await tester.pump();
    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.value, 1.0);
    expect(slider.onChanged, isNull);
  });
}
