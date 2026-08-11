import 'package:flutter/material.dart';

import '../../../shared/widgets/wavy_progress_indicator.dart';

/// A seekable playback position control drawn as a gentle wave.
///
/// The API deliberately mirrors [Slider] — [value], [max], [onChanged],
/// [onChangeEnd] — so a call site can swap between the two with one line and no
/// other changes. That is what makes falling back to the plain Material slider
/// cheap if the wave ever misbehaves on a device (see `PlaybackProgressStyle`).
///
/// Replacing a real [Slider] means its built-in accessibility has to be replaced
/// too, so this declares the slider role itself: screen readers announce the
/// elapsed and total time and can seek with the increase/decrease actions,
/// stepping by [_semanticStepFraction] of the track (never less than
/// [_minSemanticStep], so a long song doesn't take a hundred taps to cross).
class WavySeekBar extends StatelessWidget {
  const WavySeekBar({
    required this.value,
    required this.max,
    required this.onChanged,
    required this.onChangeEnd,
    required this.semanticFormatter,
    this.playing = false,
    super.key,
  });

  /// The current position in milliseconds, already reflecting an in-progress
  /// drag when the parent is previewing one.
  final double value;

  /// The track length in milliseconds. Zero means the duration is not known
  /// yet: the bar renders flat and empty rather than guessing.
  final double max;

  /// Called continuously while the user drags or taps, for a live preview.
  /// Null disables interaction entirely.
  final ValueChanged<double>? onChanged;

  /// Called once when the gesture completes, with the position to seek to.
  final ValueChanged<double>? onChangeEnd;

  /// Renders a millisecond position as the `m:ss` text screen readers announce.
  final String Function(double milliseconds) semanticFormatter;

  /// Whether playback is actively playing. The wave rides at full amplitude
  /// while it is, and eases down to a calmer, shallower wave when paused.
  final bool playing;

  /// Height of the touch target. The painted line is much thinner; the box is
  /// sized for a comfortable, WCAG-sized target instead.
  static const double _hitHeight = 44.0;

  static const double _amplitude = 3.0;

  /// Long enough that the line reads as a slow wave rather than a tight
  /// squiggle at phone widths (roughly a dozen crests across a full track).
  static const double _wavelength = 28.0;
  static const double _strokeWidth = 3.0;
  static const double _thumbRadius = 6.0;

  /// One increase/decrease action moves this much of the track…
  static const double _semanticStepFraction = 0.05;

  /// …but never less than this, so short tracks still step sensibly.
  static const Duration _minSemanticStep = Duration(seconds: 5);

  bool get _enabled => max > 0 && onChanged != null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final double fraction = max > 0 ? (value / max).clamp(0.0, 1.0) : 0.0;

    final Widget bar = LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;

        /// Maps a local touch x to a position in milliseconds, using the exact
        /// inset the painter reserved for the marker so the point the user
        /// touches is the point the marker lands on.
        double positionAt(double dx) {
          final double inset = WavyProgressIndicator.trackInset(
            thumbRadius: _thumbRadius,
            strokeWidth: _strokeWidth,
          );
          final double trackWidth = width - inset * 2;
          if (trackWidth <= 0) return 0;
          final double travelled =
              Directionality.of(context) == TextDirection.rtl
                  ? (width - inset) - dx
                  : dx - inset;
          return (travelled / trackWidth).clamp(0.0, 1.0) * max;
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: _enabled
              ? (details) => onChanged!(positionAt(details.localPosition.dx))
              : null,
          onTapUp: _enabled
              ? (details) =>
                  onChangeEnd?.call(positionAt(details.localPosition.dx))
              : null,
          onHorizontalDragStart: _enabled
              ? (details) => onChanged!(positionAt(details.localPosition.dx))
              : null,
          onHorizontalDragUpdate: _enabled
              ? (details) => onChanged!(positionAt(details.localPosition.dx))
              : null,
          onHorizontalDragEnd:
              _enabled ? (details) => onChangeEnd?.call(value) : null,
          child: SizedBox(
            height: _hitHeight,
            width: double.infinity,
            child: WavyProgressIndicator(
              value: fraction,
              activeColor: theme.colorScheme.secondary,
              inactiveColor:
                  theme.colorScheme.onSurface.withValues(alpha: 0.15),
              amplitude: _amplitude,
              wavelength: _wavelength,
              strokeWidth: _strokeWidth,
              // With no duration there is nothing to point at, so the marker is
              // withheld rather than parked misleadingly at the start.
              thumbRadius: max > 0 ? _thumbRadius : 0.0,
              active: playing,
            ),
          ),
        );
      },
    );

    return _seekSemantics(child: bar);
  }

  /// Declares the slider role a real [Slider] would have provided, with the
  /// spoken value and — when seeking is possible — the two seek actions.
  Widget _seekSemantics({required Widget child}) {
    if (!_enabled) {
      return Semantics(
        label: 'Playback position',
        value: max > 0
            ? '${semanticFormatter(value)} of ${semanticFormatter(max)}'
            : 'Unknown',
        readOnly: true,
        container: true,
        excludeSemantics: true,
        child: child,
      );
    }

    final double step = _semanticStep;
    final double increased = (value + step).clamp(0.0, max);
    final double decreased = (value - step).clamp(0.0, max);
    return Semantics(
      slider: true,
      container: true,
      excludeSemantics: true,
      label: 'Playback position',
      value: '${semanticFormatter(value)} of ${semanticFormatter(max)}',
      increasedValue: '${semanticFormatter(increased)} of '
          '${semanticFormatter(max)}',
      decreasedValue: '${semanticFormatter(decreased)} of '
          '${semanticFormatter(max)}',
      onIncrease: () => onChangeEnd?.call(increased),
      onDecrease: () => onChangeEnd?.call(decreased),
      child: child,
    );
  }

  double get _semanticStep {
    final double proportional = max * _semanticStepFraction;
    final double floor = _minSemanticStep.inMilliseconds.toDouble();
    return proportional > floor ? proportional : floor;
  }
}
