import 'package:flutter/material.dart';

import '../theme.dart';
import 'liquid.dart';

/// The 「示例」 tag. In this app colour and structure carry meaning, so exactly
/// one marker is allowed to say "this number is not yours" — and it is never
/// mixed into a panel whose figures are real.
class SampleTag extends StatelessWidget {
  const SampleTag({super.key, this.label = '示例'});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: kWarn.withOpacity(0.14),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: kWarn.withOpacity(0.4)),
      ),
      child: Text(
        label,
        style: labelStyle(color: kWarn, size: 10.5, weight: FontWeight.w600),
      ),
    );
  }
}

/// A figure with its unit set a size down — one typographic object instead of a
/// string glued together with punctuation.
class Figure extends StatelessWidget {
  const Figure({
    super.key,
    required this.value,
    this.unit,
    this.size = 22,
    this.color = kText,
  });

  final String value;
  final String? unit;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(value, style: figureStyle(size, color: color)),
        if (unit != null) ...[
          const SizedBox(width: 3),
          Text(unit!,
              style:
                  unitStyle(color: color.withOpacity(0.6), size: size * 0.46)),
        ],
      ],
    );
  }
}

/// A panel: a pane of glass on the water, holding a flat ledger inside it.
/// Heading, optional hint, optional sample tag, hairline-separated body.
class Panel extends StatelessWidget {
  const Panel({
    super.key,
    required this.title,
    this.hint,
    this.sample = false,
    this.trailing,
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(18, 16, 18, 18),
  });

  final String title;
  final String? hint;
  final bool sample;
  final Widget? trailing;
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        style: const TextStyle(
                          color: kText,
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.1,
                        ),
                      ),
                    ),
                    if (sample) ...[
                      const SizedBox(width: 8),
                      const SampleTag(),
                    ],
                  ],
                ),
              ),
              if (hint != null)
                Text(hint!, style: labelStyle(color: kMuted, size: 11.5)),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 6),
          const _Hairline(),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _Hairline extends StatelessWidget {
  const _Hairline();

  @override
  Widget build(BuildContext context) =>
      Container(height: 1, color: Colors.white.withOpacity(0.10));
}

/// One line of the ledger: label and secondary facts on the left, the figure
/// with its unit on the right, an optional proportional rule underneath. This
/// replaces a stack of identically-shaped cards.
class LedgerRow extends StatelessWidget {
  const LedgerRow({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    this.unit,
    this.progress,
    this.progressColor = kAccent,
    this.footnote,
    this.leading,
  });

  final String title;
  final String? subtitle;
  final String value;
  final String? unit;

  /// 0..1 of the row's share within its panel, drawn as a hairline-thin rule.
  final double? progress;
  final Color progressColor;

  /// Secondary facts under the row. Built from separate [Text] widgets rather
  /// than one string glued together with punctuation — see [RowFootnotes].
  final Widget? footnote;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (leading != null) ...[leading!, const SizedBox(width: 10)],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: kText,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 3),
                      Text(subtitle!,
                          style: labelStyle(color: kMuted, size: 11.5)),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Figure(value: value, unit: unit, size: 17),
            ],
          ),
          if (progress != null) ...[
            const SizedBox(height: 9),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: progress!.clamp(0.0, 1.0),
                minHeight: 3,
                backgroundColor: Colors.white.withOpacity(0.09),
                valueColor: AlwaysStoppedAnimation<Color>(progressColor),
              ),
            ),
          ],
          if (footnote != null) ...[
            const SizedBox(height: 6),
            footnote!,
          ],
        ],
      ),
    );
  }
}

/// Two secondary facts on one line — a primary one left, a secondary one right.
/// Two [Text] widgets, so each stays greppable, selectable and translatable
/// instead of being welded into a single string with punctuation.
class RowFootnotes extends StatelessWidget {
  const RowFootnotes({super.key, required this.left, this.right});

  final String left;
  final String? right;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(left, style: labelStyle(color: kFaint, size: 11)),
        if (right != null) ...[
          const Spacer(),
          Text(right!, style: labelStyle(color: kFaint, size: 11)),
        ],
      ],
    );
  }
}

/// Aligned label-over-figure cells. Used where a row of counters previously
/// lived in one string glued with middle dots.
class StatStrip extends StatelessWidget {
  const StatStrip({super.key, required this.cells, this.columns});

  final List<({String label, String value, String? unit})> cells;
  final int? columns;

  @override
  Widget build(BuildContext context) {
    final cols = columns ?? cells.length;
    final rows = <Widget>[];
    for (var i = 0; i < cells.length; i += cols) {
      final slice = cells.sublist(i, (i + cols).clamp(0, cells.length));
      rows.add(Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final c in slice) Expanded(child: _cell(c)),
        ],
      ));
      if (i + cols < cells.length) rows.add(const SizedBox(height: 14));
    }
    return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
  }

  Widget _cell(({String label, String value, String? unit}) c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(c.label, style: labelStyle(color: kFaint, size: 11)),
        const SizedBox(height: 5),
        Figure(value: c.value, unit: c.unit, size: 18),
      ],
    );
  }
}

/// Proportional rule used inside panels that list token composition.
class ProportionBar extends StatelessWidget {
  const ProportionBar({
    super.key,
    required this.label,
    required this.value,
    required this.total,
    required this.color,
  });

  final String label;
  final int value;
  final int total;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final share = total == 0 ? 0.0 : value / total;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                  child:
                      Text(label, style: labelStyle(color: kMuted, size: 12))),
              Text(
                fmtTokens(value),
                style: figureStyle(13, color: kText, weight: FontWeight.w600),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 46,
                child: Text(
                  '${(share * 100).toStringAsFixed(1)}%',
                  textAlign: TextAlign.right,
                  style: labelStyle(color: kFaint, size: 11.5),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: share.clamp(0.0, 1.0),
              minHeight: 4,
              backgroundColor: Colors.white.withOpacity(0.09),
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
        ],
      ),
    );
  }
}
