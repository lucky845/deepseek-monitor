import 'dart:ui';

import 'package:flutter/material.dart';

import '../providers/glass_provider.dart';
import '../theme.dart';

/// The tank. Daylight falls in at the top, the water darkens with depth, a
/// fixed light hangs off each corner, and the mascot swims down in the corner.
/// All of it is static: the page gets exactly one animated moment (the
/// entrance fade), and glass over a moving background is noise, not depth.
///
/// None of it is decoration either — glass is only readable when there is
/// something behind it to bend. A flat backdrop makes every pane look like a
/// plain dark card, so the water carries real luminance, and the character
/// gives the panes a subject to blur.
class WaterBackdrop extends StatelessWidget {
  const WaterBackdrop({super.key, required this.child, this.mascotLive = true});

  final Widget child;

  /// She dims with the data: live when the figures are real, quiet when the
  /// page is showing its sample set.
  final bool mascotLive;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [0.0, 0.14, 0.42, 1.0],
                colors: [kWaterTop, kWaterLit, kWater, kBg],
              ),
            ),
          ),
        ),
        // Daylight entering the surface, as a soft diagonal shaft.
        Positioned(
          left: -80,
          top: -260,
          child: Transform.rotate(
            angle: 0.38,
            child: Container(
              width: 300,
              height: 900,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.white.withOpacity(0.13),
                    Colors.white.withOpacity(0.0),
                  ],
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: -180,
          top: 30,
          child: _Bloom(diameter: 760, color: kFish.withOpacity(0.32)),
        ),
        Positioned(
          right: -240,
          top: 300,
          child: _Bloom(diameter: 900, color: kChartOut.withOpacity(0.18)),
        ),
        Positioned(
          left: 120,
          bottom: -300,
          child: _Bloom(diameter: 820, color: kAccent.withOpacity(0.20)),
        ),
        // She lives under the panes, not on top of them: the corner of the tank
        // is hers, and every pane of glass above her has something to refract.
        Positioned(
          right: -30,
          bottom: 26,
          child: IgnorePointer(
            child: Opacity(
              // Loud enough to be found, quiet enough to read numbers over.
              opacity: 0.30,
              child: Mascot(size: 320, live: mascotLive),
            ),
          ),
        ),
        Positioned.fill(child: child),
      ],
    );
  }
}

class _Bloom extends StatelessWidget {
  const _Bloom({required this.diameter, required this.color});

  final double diameter;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: diameter,
        height: diameter,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [color, color.withOpacity(0)],
            stops: const [0.0, 1.0],
          ),
        ),
      ),
    );
  }
}

/// One pane of glass. Real liquid glass has three readable parts, so it gets
/// all three and nothing more: a fill that is brighter where the light hits, a
/// 1px rim that catches the surface, and a single specular thread along the top
/// edge. No decoration inside — whatever goes in here stays flat.
///
/// Thickness comes from the [GlassScope] setting, so one slider moves every
/// pane at once.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.radius = 18,
    this.padding,
    this.blur = 18,
    this.tint,
    this.tintStrength = 0.0,
    this.specular = true,
    this.shadow = true,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry? padding;
  final double blur;

  /// Optional hue for the pane, used where the glass must carry a warning
  /// rather than just sit there (the sample-data notice).
  final Color? tint;
  final double tintStrength;
  final bool specular;
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final double k = GlassScope.strengthOf(context);
    final r = BorderRadius.circular(radius);
    final fillTop = tint == null
        ? Colors.white.withOpacity(kGlassTop * k)
        : Color.lerp(
            Colors.white.withOpacity(kGlassTop * k), tint!, tintStrength)!;
    final fillBottom = tint == null
        ? Colors.white.withOpacity(kGlassBottom * k)
        : Color.lerp(
            Colors.white.withOpacity(kGlassBottom * k), tint!, tintStrength)!;
    final double rim = (kGlassRim * (0.55 + 0.45 * k)).clamp(0.0, 1.0);
    final double sigma = (blur * (0.35 + 0.65 * k)).clamp(2.0, 40.0);

    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: r,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: r,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [fillTop, fillBottom],
              ),
              border: Border.all(
                color: tint == null
                    ? Colors.white.withOpacity(rim)
                    : tint!.withOpacity(0.42),
              ),
              boxShadow: shadow
                  ? const [
                      BoxShadow(
                        color: kGlassShadow,
                        blurRadius: 26,
                        offset: Offset(0, 10),
                      ),
                    ]
                  : null,
            ),
            child: Stack(
              children: [
                if (specular)
                  Positioned(
                    left: radius * 0.9,
                    right: radius * 0.9,
                    top: 0,
                    child: Container(
                      height: 1,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Colors.white.withOpacity(0),
                            Colors.white
                                .withOpacity((0.52 * k).clamp(0.0, 1.0)),
                            Colors.white.withOpacity(0),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (padding != null)
                  Padding(padding: padding!, child: child)
                else
                  child,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The character herself: DeepSeek 娘, the blue whale-girl in a maid apron
/// that the community draws. She is the app's one borrowed thing — the art is
/// a fan work, credited in the README, and nothing here is redrawn by hand.
///
/// [live] is the whole state signal: lit when the numbers around her are the
/// person's own, faded when they are the sample set.
class Mascot extends StatelessWidget {
  const Mascot(
      {super.key, this.size = 40, this.live = true, this.head = false});

  final double size;
  final bool live;

  /// Cropped to the face. Full body art is unreadable at 46px.
  final bool head;

  static const List<double> _grey = <double>[
    0.55,
    0.55,
    0.55,
    0,
    0,
    0.55,
    0.55,
    0.55,
    0,
    0,
    0.55,
    0.55,
    0.55,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ];

  @override
  Widget build(BuildContext context) {
    final Widget art = Image.asset(
      head ? 'assets/mascot_head.png' : 'assets/mascot.png',
      width: size,
      height: size,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
    );
    // A face crop reads as a badge, so it stays in colour: dimming a 46px
    // figure just turns it into a grey smudge. Only the full-body figure
    // carries the asleep state.
    if (live || head) return art;
    // Asleep, not gone: she keeps her shape but loses her colour, so a sample
    // page still has a character on it without pretending to be real data.
    return Opacity(
      opacity: 0.62,
      child: ColorFiltered(
        colorFilter: const ColorFilter.matrix(_grey),
        child: art,
      ),
    );
  }
}
