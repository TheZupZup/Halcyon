import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../../core/models/lyric_focus.dart';
import 'lyric_line_tile.dart';

/// A timed lyric line that follows the active line on its own.
///
/// This is the piece that keeps the synced view cheap. The viewport publishes
/// the active line index as a [ValueListenable] instead of rebuilding through
/// it, and each row subscribes directly — then repaints **only when its own
/// [LyricEmphasis] changes**. Crossing a line boundary therefore touches the
/// handful of rows whose emphasis actually moved (the old and new active lines
/// and their neighbours), not every row the list happens to have built, and the
/// list itself is never rebuilt at all.
///
/// It holds no timing logic: the index arrives ready-made from the playback
/// position, and [lyricEmphasisFor] turns it into emphasis.
class SyncedLyricLine extends StatefulWidget {
  const SyncedLyricLine({
    required this.activeLine,
    required this.index,
    required this.text,
    this.onSeek,
    super.key,
  });

  /// The index of the line playing right now, as published by the viewport.
  final ValueListenable<int> activeLine;

  /// This line's position in the lyrics.
  final int index;

  final String text;

  /// Seeks playback to this line's timestamp. Null for a line with no
  /// timestamp, which then isn't tappable.
  final VoidCallback? onSeek;

  @override
  State<SyncedLyricLine> createState() => _SyncedLyricLineState();
}

class _SyncedLyricLineState extends State<SyncedLyricLine> {
  late LyricEmphasis _emphasis = _emphasisNow();

  @override
  void initState() {
    super.initState();
    widget.activeLine.addListener(_onActiveLineChanged);
  }

  @override
  void didUpdateWidget(SyncedLyricLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeLine != widget.activeLine) {
      oldWidget.activeLine.removeListener(_onActiveLineChanged);
      widget.activeLine.addListener(_onActiveLineChanged);
    }
    // A recycled row now standing in for a different line (or a different
    // song's notifier) must re-derive its emphasis rather than keep the old
    // one. No setState — a rebuild is already under way.
    if (oldWidget.index != widget.index ||
        oldWidget.activeLine != widget.activeLine) {
      _emphasis = _emphasisNow();
    }
  }

  @override
  void dispose() {
    widget.activeLine.removeListener(_onActiveLineChanged);
    super.dispose();
  }

  LyricEmphasis _emphasisNow() => lyricEmphasisFor(
        index: widget.index,
        activeIndex: widget.activeLine.value,
      );

  void _onActiveLineChanged() {
    final LyricEmphasis next = _emphasisNow();
    // The guard is the point: most line changes leave most rows' emphasis
    // untouched, and those rows must not repaint.
    if (next == _emphasis) return;
    setState(() => _emphasis = next);
  }

  @override
  Widget build(BuildContext context) {
    return LyricLineTile(
      text: widget.text,
      emphasis: _emphasis,
      onTap: widget.onSeek,
    );
  }
}
