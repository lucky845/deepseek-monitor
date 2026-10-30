import 'package:flutter/material.dart';

/// The app is a metering instrument, not a card gallery. Two rules shape this
/// palette:
///
/// 1. Colour encodes **truth**, not decoration. `kAccent` marks figures we got
///    from DeepSeek; `kWarn` marks the sample set. Nothing else gets a hue.
/// 2. `kChart*` colours exist only inside charts, where colour encodes a
///    category (cache hit / miss / output) and carries real information.
const kBg = Color(0xFF04070F);

/// The instrument sits in water, so the base is not flat black: light comes
/// from above the surface and dies in the abyss. Glass needs something real to
/// refract, and this is it.
const kWater = Color(0xFF0A1836);

/// The bright band just under the surface, where daylight enters the tank.
const kWaterTop = Color(0xFF1E5A96);
const kWaterLit = Color(0xFF123A6B);
const kSurface = Color(0xFF0F1522);
const kSurface2 = Color(0xFF1B2334);
const kLine = Color(0xFF212C42);
const kAccent = Color(0xFF6C8BFF);
const kWarn = Color(0xFFD9A036);
const kDanger = Color(0xFFEF4444);
const kText = Color(0xFFE9EEF8);
const kMuted = Color(0xFF7C8AA3);
const kFaint = Color(0xFF55617A);

/// Chart-only categorical colours.
const kChartHit = Color(0xFF3DD68C);
const kChartMiss = Color(0xFFD9A036);
const kChartOut = Color(0xFF4CC3E0);

/// The mascot is a third blue on purpose: it reads as a creature in the water,
/// never as the accent that marks real figures.
const kFish = Color(0xFF3C7DFF);

/// The mascot's only warm colours. She is the single warm thing on the
/// page, which is exactly why the eye lands on her first.

/// Kept for the legacy names still referenced by the connect sheet.
const kAccent2 = kChartOut;
const kSuccess = kChartHit;

/// Figures are the personality of this app: tabular so columns line up, tight
/// so large readouts don't drift apart, and always paired with a unit set a
/// size down rather than shouted at the same weight.
const List<FontFeature> kTabular = [FontFeature.tabularFigures()];

TextStyle figureStyle(
  double size, {
  Color color = kText,
  FontWeight weight = FontWeight.w700,
  double tracking = -0.5,
}) =>
    TextStyle(
      color: color,
      fontSize: size,
      fontWeight: weight,
      letterSpacing: tracking,
      height: 1.05,
      fontFeatures: kTabular,
    );

TextStyle unitStyle({
  Color color = kMuted,
  double size = 12,
  FontWeight weight = FontWeight.w600,
}) =>
    TextStyle(
      color: color,
      fontSize: size,
      fontWeight: weight,
      letterSpacing: 0.1,
      fontFeatures: kTabular,
    );

TextStyle labelStyle({
  Color color = kFaint,
  double size = 11,
  FontWeight weight = FontWeight.w500,
  double tracking = 0.2,
}) =>
    TextStyle(
        color: color,
        fontSize: size,
        fontWeight: weight,
        letterSpacing: tracking);

TextStyle bodyStyle({
  Color color = kMuted,
  double size = 12.5,
  FontWeight weight = FontWeight.w400,
  double height = 1.5,
}) =>
    TextStyle(color: color, fontSize: size, fontWeight: weight, height: height);

/// Compact token count: 1.2K / 3.4M / 1.05B.
String fmtTokens(int n) {
  if (n >= 1000000000) return '${(n / 1000000000).toStringAsFixed(2)}B';
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
  return '$n';
}

/// Shared panel chrome. Kept as flat surfaces for anything that must stay
/// legible against the water; the liquid shells live in `widgets/liquid.dart`.
BoxDecoration panelDecoration({double radius = 14}) => BoxDecoration(
      color: kSurface,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: kLine),
    );

/// Glass fill: brighter where the light hits, thinner where it falls away.
const double kGlassTop = 0.13;
const double kGlassBottom = 0.04;
const double kGlassRim = 0.20;
const Color kGlassShadow = Color(0x66000000);
