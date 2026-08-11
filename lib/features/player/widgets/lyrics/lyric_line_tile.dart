import 'package:flutter/material.dart';

import '../../../../app/dimens.dart';
import '../../../../core/models/lyric_focus.dart';

/// One line of lyrics, styled for its [emphasis].
///
/// The single place a [LyricEmphasis] becomes type, colour, and weight — used by
/// both the synced and the plain viewport, so a timed and an untimed line share
/// their metrics and only differ where they genuinely should.
///
/// Every colour is read from the [ColorScheme], so the tile retints with the
/// user's branding theme and works in light and dark without a hard-coded value.
/// The active line is never distinguished by colour *alone*: it is also larger
/// and heavier, carries an accent marker in the gutter, and reports itself as
/// selected to screen readers.
class LyricLineTile extends StatelessWidget {
  const LyricLineTile({
    required this.text,
    required this.emphasis,
    this.onTap,
    super.key,
  });

  /// The line's text. May be empty — a deliberate blank between stanzas, which
  /// keeps its vertical rhythm rather than collapsing.
  final String text;

  final LyricEmphasis emphasis;

  /// Seeks playback to this line, for a timed line the user can jump to. Null
  /// leaves the line inert (plain lyrics, or a timed set's untimed leftovers),
  /// and the tile then claims no tap target and no button semantics.
  ///
  /// Ignored for a blank line even when one is supplied — see [build].
  final VoidCallback? onTap;

  /// The smallest comfortable height for a seekable line. Lyric rows are short
  /// text, so left alone they would be well under the accessible minimum.
  static const double minTapTargetHeight = 48;

  /// Width reserved for the active-line marker on *timed* lyrics. Held even
  /// when the marker isn't drawn, so the text never reflows as the active line
  /// moves.
  static const double _markerGutter = 16;

  static const double _markerWidth = 3;
  static const double _markerHeight = 16;

  /// How long a line takes to settle into its new emphasis. Long enough to read
  /// as a transition, short enough that a quick run of lines doesn't smear.
  static const Duration transition = Duration(milliseconds: 220);

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    final Duration duration = reduceMotion ? Duration.zero : transition;
    // A blank line is stanza rhythm, not content — and an `.lrc` can legally
    // give one a timestamp (`[00:10.00]` with nothing after it), which
    // LyricsTextParser preserves. Such a row must stay pure spacing: seeking to
    // it would offer an unlabelled button with a "Play from this line" hint, and
    // marking it would float an accent pill beside nothing. So blankness, not
    // just the absence of a timestamp, decides whether a line is interactive.
    final bool isBlank = text.trim().isEmpty;
    final VoidCallback? onTapLine = isBlank ? null : onTap;

    Widget line = Row(
      children: <Widget>[
        // Plain lyrics have no active line, so they get no gutter at all and
        // sit flush — the layout itself says "nothing here is highlighted".
        if (emphasis != LyricEmphasis.untimed)
          _ActiveMarker(
            active: !isBlank && emphasis == LyricEmphasis.active,
            duration: duration,
          ),
        Expanded(
          child: AnimatedDefaultTextStyle(
            duration: duration,
            curve: Curves.easeOut,
            style: styleFor(theme, emphasis),
            child: Text(isBlank ? ' ' : text),
          ),
        ),
      ],
    );

    line = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.sm,
      ),
      child: line,
    );

    if (onTapLine == null) {
      // A blank stanza gap is spacing, not content: it would otherwise be read
      // out as an empty item between two lines.
      return isBlank ? ExcludeSemantics(child: line) : line;
    }

    return MergeSemantics(
      child: Semantics(
        // Screen readers get the same "this is the line playing" signal the eye
        // does, rather than inferring it from a colour they never see.
        selected: emphasis == LyricEmphasis.active,
        button: true,
        hint: 'Play from this line',
        child: Material(
          // Transparent so the artwork backdrop shows through; present so the
          // tap still lands an ink ripple wherever the tile is hosted.
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTapLine,
            borderRadius: BorderRadius.circular(AppRadii.sm),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: minTapTargetHeight),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: line,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The text style for [emphasis], derived entirely from [theme].
  ///
  /// The progression is opacity *and* weight, not opacity alone, so the active
  /// line stays dominant even where a bright cover pushes the contrast around.
  /// Sizes come from the text theme, so the user's text scaling multiplies them
  /// rather than fighting a fixed value.
  static TextStyle styleFor(ThemeData theme, LyricEmphasis emphasis) {
    final ColorScheme colors = theme.colorScheme;
    final TextStyle base = theme.textTheme.titleMedium ?? const TextStyle();
    switch (emphasis) {
      case LyricEmphasis.active:
        return base.copyWith(
          color: colors.onSurface,
          fontSize: (base.fontSize ?? 16) * 1.25,
          fontWeight: FontWeight.w700,
          height: 1.3,
          letterSpacing: -0.2,
        );
      case LyricEmphasis.adjacent:
        return base.copyWith(
          color: colors.onSurface.withValues(alpha: 0.62),
          fontWeight: FontWeight.w500,
          height: 1.35,
        );
      case LyricEmphasis.near:
        return base.copyWith(
          color: colors.onSurface.withValues(alpha: 0.42),
          fontWeight: FontWeight.w500,
          height: 1.35,
        );
      case LyricEmphasis.distant:
        return base.copyWith(
          color: colors.onSurface.withValues(alpha: 0.26),
          fontWeight: FontWeight.w500,
          height: 1.35,
        );
      case LyricEmphasis.untimed:
        // Plain lyrics are a reading surface, not a following one: one calm
        // weight, near-full contrast, and generous leading.
        return (theme.textTheme.bodyLarge ?? base).copyWith(
          color: colors.onSurface.withValues(alpha: 0.86),
          height: 1.7,
        );
    }
  }
}

/// The small accent pill marking the active line.
///
/// It is a *redundant* cue — the line is already larger and heavier — which is
/// what lets the active state survive a user who can't distinguish the colours.
/// Its gutter is reserved whether or not it is drawn, so the lines never shift
/// sideways as the marker moves down the song.
class _ActiveMarker extends StatelessWidget {
  const _ActiveMarker({required this.active, required this.duration});

  final bool active;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: LyricLineTile._markerGutter,
      child: Center(
        child: AnimatedOpacity(
          // Cross-fades with the text restyle above, so the two read as one
          // change rather than two. Zero-duration under reduced motion.
          duration: duration,
          curve: Curves.easeOut,
          opacity: active ? 1 : 0,
          child: Container(
            width: LyricLineTile._markerWidth,
            height: LyricLineTile._markerHeight,
            decoration: BoxDecoration(
              // The brand's energy accent — the same token the progress line
              // and play button use — so the highlight reads as Linthra's.
              color: colors.secondary,
              borderRadius: BorderRadius.circular(AppRadii.pill),
            ),
          ),
        ),
      ),
    );
  }
}
