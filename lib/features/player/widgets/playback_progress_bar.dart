import 'package:flutter/material.dart';

import '../../../app/dimens.dart';
import 'wavy_seek_bar.dart';

/// How the seekable progress bar is drawn.
enum PlaybackProgressStyle {
  /// Linthra's own [WavySeekBar]: a soft serpentine line with a round marker.
  wave,

  /// The plain Material [Slider]. Kept as a first-class, tested path so a single
  /// constant reverts the look if the wave ever proves problematic on a device.
  slider,
}

/// The style [PlaybackProgressBar] uses unless a call site overrides it. Change
/// this one value to move the whole app back to the Material slider.
const PlaybackProgressStyle defaultPlaybackProgressStyle =
    PlaybackProgressStyle.wave;

/// Seekable progress bar showing the current position and total duration.
///
/// Robust to an unknown duration (common at the very start of a stream or for a
/// live source): when [duration] is zero the bar sits stable and disabled and
/// the total reads `--:--`, so the UI never breaks or jumps. While the user
/// drags, the marker and the elapsed label follow the finger; the actual
/// [onSeek] fires once on release, so playback isn't spammed mid-drag.
///
/// The drag preview lives here rather than in either renderer, so both the wave
/// and the slider stay interchangeable and the time labels follow the finger the
/// same way in both.
class PlaybackProgressBar extends StatefulWidget {
  const PlaybackProgressBar({
    required this.position,
    required this.duration,
    required this.onSeek,
    this.playing = false,
    this.style = defaultPlaybackProgressStyle,
    super.key,
  });

  final Duration position;
  final Duration duration;

  /// Called with the target position when a seek completes. The bar still
  /// renders progress when this is null, just without seeking.
  final ValueChanged<Duration>? onSeek;

  /// Whether playback is actively playing. Only the wave's slow drift uses this;
  /// a paused bar holds still and schedules no frames.
  final bool playing;

  /// Which renderer to use. Defaults to [defaultPlaybackProgressStyle].
  final PlaybackProgressStyle style;

  @override
  State<PlaybackProgressBar> createState() => _PlaybackProgressBarState();
}

class _PlaybackProgressBarState extends State<PlaybackProgressBar> {
  /// The in-progress drag position in milliseconds, or null when not dragging.
  double? _dragMs;

  void _onChanged(double value) => setState(() => _dragMs = value);

  void _onChangeEnd(double value) {
    widget.onSeek?.call(Duration(milliseconds: value.round()));
    setState(() => _dragMs = null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final int totalMs = widget.duration.inMilliseconds;
    final bool hasDuration = totalMs > 0;
    final bool canSeek = hasDuration && widget.onSeek != null;

    final int posMs = hasDuration
        ? widget.position.inMilliseconds.clamp(0, totalMs).toInt()
        : 0;
    final double barValue = _dragMs ?? posMs.toDouble();

    final muted = theme.colorScheme.onSurfaceVariant;
    final labelStyle = theme.textTheme.labelSmall?.copyWith(
      color: muted,
      letterSpacing: 0.4,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    return Column(
      children: [
        switch (widget.style) {
          PlaybackProgressStyle.wave => WavySeekBar(
              value: barValue,
              max: hasDuration ? totalMs.toDouble() : 0.0,
              onChanged: canSeek ? _onChanged : null,
              onChangeEnd: canSeek ? _onChangeEnd : null,
              semanticFormatter: _formatMs,
              playing: widget.playing,
            ),
          PlaybackProgressStyle.slider => SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                inactiveTrackColor:
                    theme.colorScheme.onSurface.withValues(alpha: 0.15),
              ),
              child: Slider(
                value: barValue,
                max: hasDuration ? totalMs.toDouble() : 1.0,
                onChanged: canSeek ? _onChanged : null,
                onChangeEnd: canSeek ? _onChangeEnd : null,
              ),
            ),
        },
        // Snug under the track and aligned to its ends, so the times read as a
        // caption for the bar rather than a separate, floating row.
        Padding(
          padding: const EdgeInsets.only(top: AppSpacing.xs),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_formatMs(barValue), style: labelStyle),
              Text(
                hasDuration ? _format(widget.duration) : '--:--',
                style: labelStyle,
              ),
            ],
          ),
        ),
      ],
    );
  }

  static String _formatMs(double milliseconds) =>
      _format(Duration(milliseconds: milliseconds.round()));

  /// `m:ss`, widening to `h:mm:ss` past an hour.
  static String _format(Duration d) {
    final int totalSeconds = d.inSeconds;
    final int hours = totalSeconds ~/ 3600;
    final int minutes = (totalSeconds % 3600) ~/ 60;
    final int seconds = totalSeconds % 60;
    final String ss = seconds.toString().padLeft(2, '0');
    if (hours > 0) {
      final String mm = minutes.toString().padLeft(2, '0');
      return '$hours:$mm:$ss';
    }
    return '$minutes:$ss';
  }
}
