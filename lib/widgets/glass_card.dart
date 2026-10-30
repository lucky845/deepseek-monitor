import 'package:flutter/material.dart';

import '../providers/glass_provider.dart';
import '../theme.dart';
import 'ledger.dart';
import 'liquid.dart';

/// The one setting that changes the room rather than the data: how thick the
/// panes are. It shows its own effect — the preview strip is a real pane over a
/// real piece of water, so nothing has to be explained in words.
class GlassCard extends StatelessWidget {
  const GlassCard({super.key});

  @override
  Widget build(BuildContext context) {
    final glass = GlassScope.of(context);
    final double k = glass?.strength ?? 1.0;

    return Panel(
      title: '玻璃透明度',
      hint: glass?.label ?? '标准',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Preview(),
          const SizedBox(height: 14),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              activeTrackColor: kAccent,
              inactiveTrackColor: Colors.white.withOpacity(0.14),
              thumbColor: kText,
              overlayColor: kAccent.withOpacity(0.16),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
            ),
            child: Slider(
              value: k,
              min: kGlassMin,
              max: kGlassMax,
              onChanged: glass == null ? null : (v) => glass.setStrength(v),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('通透', style: labelStyle(color: kMuted, size: 11)),
                Text('厚重', style: labelStyle(color: kMuted, size: 11)),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              for (final p in const <({String label, double value})>[
                (label: '通透', value: 0.5),
                (label: '标准', value: 1.0),
                (label: '厚重', value: 1.3),
              ])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: _Preset(
                    label: p.label,
                    selected: (k - p.value).abs() < 0.05,
                    onTap:
                        glass == null ? null : () => glass.setStrength(p.value),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A strip of water with one pane on it, drawn with the live setting.
class _Preview extends StatelessWidget {
  const _Preview();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 62,
      child: Stack(
        children: [
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(11),
              child: const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [kWaterTop, kWater, kBg],
                  ),
                ),
              ),
            ),
          ),
          const Positioned(
            left: -30,
            top: -20,
            child: _Lit(diameter: 130, color: kFish),
          ),
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.all(9),
              child: GlassSurface(
                radius: 11,
                blur: 14,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Text('透过玻璃的文字与数字',
                        style: labelStyle(color: kMuted, size: 11.5)),
                    const Spacer(),
                    const Figure(value: 'Aa', unit: '123', size: 16),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Lit extends StatelessWidget {
  const _Lit({required this.diameter, required this.color});

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
            colors: [color.withOpacity(0.5), color.withOpacity(0)],
          ),
        ),
      ),
    );
  }
}

class _Preset extends StatelessWidget {
  const _Preset({required this.label, required this.selected, this.onTap});

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? kAccent.withOpacity(0.18)
              : Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            color: selected
                ? kAccent.withOpacity(0.55)
                : Colors.white.withOpacity(0.10),
          ),
        ),
        child: Text(
          label,
          style: labelStyle(
            color: selected ? kText : kMuted,
            size: 12,
            weight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}
