import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How thick the glass is. This is a taste setting, not a data setting: it
/// changes nothing about what the page claims, only how much of the tank you
/// can see through the panels.
const double kGlassMin = 0.35;
const double kGlassMax = 1.35;

class GlassProvider extends ChangeNotifier {
  static const String _kStrength = 'glass_strength';

  double _strength = 1.0;
  double get strength => _strength;

  /// A word for the current setting, so the slider has a readable position.
  String get label {
    if (_strength < 0.7) return '通透';
    if (_strength > 1.1) return '厚重';
    return '标准';
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _strength =
        (prefs.getDouble(_kStrength) ?? 1.0).clamp(kGlassMin, kGlassMax);
    notifyListeners();
  }

  Future<void> setStrength(double value) async {
    _strength = value.clamp(kGlassMin, kGlassMax);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kStrength, _strength);
  }
}

/// Publishes the glass setting to every [GlassSurface] in the tree.
///
/// An `InheritedNotifier` rather than a Provider lookup on purpose: glass is
/// drawn by leaf widgets (panels, chips, dock) and by widgets that are pumped
/// on their own in tests, and every one of them must still render with a sane
/// default when no scope is above it.
class GlassScope extends InheritedNotifier<GlassProvider> {
  const GlassScope({
    super.key,
    required GlassProvider super.notifier,
    required super.child,
  });

  static GlassProvider? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GlassScope>()?.notifier;

  /// 1.0 when nothing published a setting — the untouched look.
  static double strengthOf(BuildContext context) =>
      of(context)?.strength ?? 1.0;
}
