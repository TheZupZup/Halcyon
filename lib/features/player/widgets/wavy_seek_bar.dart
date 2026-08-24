import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/dimens.dart';
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
///
/// A real [Slider] is also keyboard-operable, which matters wherever there is a
/// keyboard — a desktop window, but equally an Android tablet with a keyboard
/// case — so that is replaced too: the bar takes Tab focus, draws a focus ring
/// while it holds it, and seeks by the same step on the left/right arrow keys
/// (mirrored under RTL, exactly as [Slider] does).
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
    // The focus node is owned by [Focus] itself; the [Builder] below reads it
    // back so the ring and the slider's `focused` flag follow it without this
    // widget having to hold state of its own.
    return Focus(
      canRequestFocus: _enabled,
      skipTraversal: !_enabled,
      // The seek semantics below already declare the slider role, its value and
      // its focus state; a second, bare focus node would only add an empty
      // wrapper node around it.
      includeSemantics: false,
      onKeyEvent: (FocusNode node, KeyEvent event) => _onKeyEvent(
        context,
        event,
      ),
      child: Builder(
        builder: (BuildContext context) {
          final FocusNode node = Focus.of(context);
          return _seekSemantics(
            node: node,
            child: _bar(context, node),
          );
        },
      ),
    );
  }

  /// Seeks by one [_semanticStep] on the arrow keys, so the bar is operable
  /// from the keyboard the way [Slider] is. Left/right are read against the
  /// text direction, so "right" always means "later" on screen.
  KeyEventResult _onKeyEvent(BuildContext context, KeyEvent event) {
    if (!_enabled) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final bool rtl = Directionality.of(context) == TextDirection.rtl;
    final bool forward;
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      forward = !rtl;
    } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      forward = rtl;
    } else {
      return KeyEventResult.ignored;
    }
    final double step = forward ? _semanticStep : -_semanticStep;
    onChangeEnd?.call((value + step).clamp(0.0, max));
    return KeyEventResult.handled;
  }

  Widget _bar(BuildContext context, FocusNode node) {
    final theme = Theme.of(context);
    final double fraction = max > 0 ? (value / max).clamp(0.0, 1.0) : 0.0;

    return LayoutBuilder(
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
              ? (details) {
                  // Clicking the bar hands it the keyboard too, so the arrow
                  // keys keep seeking from where the pointer left off.
                  node.requestFocus();
                  onChanged!(positionAt(details.localPosition.dx));
                }
              : null,
          onTapUp: _enabled
              ? (details) =>
                  onChangeEnd?.call(positionAt(details.localPosition.dx))
              : null,
          onHorizontalDragStart: _enabled
              ? (details) {
                  node.requestFocus();
                  onChanged!(positionAt(details.localPosition.dx));
                }
              : null,
          onHorizontalDragUpdate: _enabled
              ? (details) => onChanged!(positionAt(details.localPosition.dx))
              : null,
          onHorizontalDragEnd:
              _enabled ? (details) => onChangeEnd?.call(value) : null,
          child: Container(
            height: _hitHeight,
            width: double.infinity,
            // A visible focus ring is the keyboard's equivalent of the pointer's
            // marker: without it, Tab moves through the transport with nothing
            // on screen saying where it landed.
            decoration: node.hasFocus
                ? BoxDecoration(
                    borderRadius: BorderRadius.circular(AppRadii.sm),
                    border: Border.all(
                      color: theme.colorScheme.secondary,
                      width: 2,
                    ),
                  )
                : null,
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
  }

  /// Declares the slider role a real [Slider] would have provided, with the
  /// spoken value and — when seeking is possible — the two seek actions.
  Widget _seekSemantics({required FocusNode node, required Widget child}) {
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
      focusable: true,
      focused: node.hasFocus,
      label: 'Playback position',
      value: '${semanticFormatter(value)} of ${semanticFormatter(max)}',
      increasedValue: '${semanticFormatter(increased)} of '
          '${semanticFormatter(max)}',
      decreasedValue: '${semanticFormatter(decreased)} of '
          '${semanticFormatter(max)}',
      onIncrease: () => onChangeEnd?.call(increased),
      onDecrease: () => onChangeEnd?.call(decreased),
      // The same "move focus here" action a real [Slider] offers, so assistive
      // tech can hand the bar the keyboard and then use the arrow keys.
      onFocus: node.requestFocus,
      child: child,
    );
  }

  double get _semanticStep {
    final double proportional = max * _semanticStepFraction;
    final double floor = _minSemanticStep.inMilliseconds.toDouble();
    return proportional > floor ? proportional : floor;
  }
}
