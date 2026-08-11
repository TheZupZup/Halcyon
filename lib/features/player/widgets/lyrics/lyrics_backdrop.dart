import 'package:flutter/material.dart';

import '../../../../app/dimens.dart';
import '../now_playing_background.dart';

/// The background treatment behind the lyrics surface.
///
/// It deliberately paints **no artwork of its own.** Now Playing already renders
/// [NowPlayingBackground] — one heavily blurred, dimmed copy of the current
/// cover, held on its own retained compositing layer — directly behind this
/// panel. Decoding and blurring a second copy would double the most expensive
/// paint on the screen to produce a picture the user is already looking at. So
/// this lays a calm veil over that existing backdrop instead: the artwork still
/// tints and blurs through, and the lyrics get a guaranteed contrast floor over
/// a washed-out cover as much as a near-black one.
///
/// Both the veil and the edge fades come from the [ColorScheme], so the panel
/// retints with the branding theme and reads correctly in light and dark. The
/// fades are plain gradient rectangles rather than a `ShaderMask`: a mask would
/// force a `saveLayer` over the whole scrolling list every frame, which is
/// exactly the cost a lower-end phone can least afford here.
class LyricsBackdrop extends StatelessWidget {
  const LyricsBackdrop({required this.child, super.key});

  final Widget child;

  /// How far the lines dissolve into the backdrop at the top and bottom edges.
  static const double _fadeExtent = 44;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    // A light theme's surface *is* the bright end of its ramp, so it needs to
    // sit heavier over the artwork to hold the same readability a dark theme
    // gets for less.
    final double veil = theme.brightness == Brightness.dark ? 0.55 : 0.74;
    final Color veilColor = colors.surface.withValues(alpha: veil);

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: veilColor,
        borderRadius: BorderRadius.circular(AppRadii.lg),
        border: Border.all(
          color: colors.onSurface.withValues(alpha: 0.06),
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          child,
          _EdgeFade(color: veilColor, alignment: Alignment.topCenter),
          _EdgeFade(color: veilColor, alignment: Alignment.bottomCenter),
        ],
      ),
    );
  }
}

/// A soft dissolve at one end of the scrolling lyrics, so lines arrive and
/// leave rather than being cut off by a hard edge.
class _EdgeFade extends StatelessWidget {
  const _EdgeFade({required this.color, required this.alignment});

  final Color color;

  /// [Alignment.topCenter] or [Alignment.bottomCenter].
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    final bool isTop = alignment == Alignment.topCenter;
    return Positioned(
      top: isTop ? 0 : null,
      bottom: isTop ? null : 0,
      left: 0,
      right: 0,
      height: LyricsBackdrop._fadeExtent,
      // Decoration only — it must never swallow a tap meant for the line
      // sitting under it.
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: isTop ? Alignment.topCenter : Alignment.bottomCenter,
              end: isTop ? Alignment.bottomCenter : Alignment.topCenter,
              colors: <Color>[color, color.withValues(alpha: 0)],
            ),
          ),
        ),
      ),
    );
  }
}
