import 'package:flutter/material.dart';

import '../../../app/dimens.dart';
import '../../../core/models/album.dart';
import 'album_grid_card.dart';

/// Narrowest a card may get before the grid drops a column. Two cards plus the
/// gutters still fit comfortably on the narrowest phones we support, which is
/// why [albumGridColumnCount] never returns fewer than [_minColumns].
const double _minCardWidth = 200;

/// Widest a card may get before the grid adds a column instead.
///
/// This is what keeps a desktop window from reading as a stretched phone: past
/// this width the extra space buys another album, not a bigger cover. Without
/// it a 2560 px window rendered six ~400 px cards — the same mobile grid, just
/// inflated.
const double _maxCardWidth = 260;

/// Phones (and anything narrower than two comfortable cards) get exactly two
/// columns; the upper bound is a sanity stop for absurd widths rather than a
/// design limit — every monitor Linthra realistically runs on is sized by
/// [_maxCardWidth] well before it.
const int _minColumns = 2;
const int _maxColumns = 12;

/// Columns for [width] logical pixels of *content* width — the space left for
/// the cards themselves, gutters included, after the grid's own padding.
///
/// Two on a phone; a column is added as soon as one more card fits at
/// [_minCardWidth], and columns keep being added while cards would otherwise
/// grow past [_maxCardWidth]. Pure so the breakpoints can be tested without
/// pumping a widget.
int albumGridColumnCount(double width) {
  if (!width.isFinite || width <= 0) return _minColumns;
  // As many as still fit at the narrow bound, and as many as it takes to keep
  // cards under the wide one. The narrow bound wins where they disagree, so a
  // card is never squeezed below [_minCardWidth] just to add a column.
  final int fits = (width / _minCardWidth).floor();
  final int dense = (width / _maxCardWidth).ceil();
  final int columns = dense < fits ? dense : fits;
  return columns.clamp(_minColumns, _maxColumns);
}

/// The Albums tab body: a responsive grid of [AlbumGridCard]s.
///
/// Every cell is sized as a square cover plus the room its two labels need at
/// the current text scale ([AlbumGridCard.labelExtent]), so cards stay aligned
/// and the artwork stays square whatever the column count.
class AlbumGrid extends StatelessWidget {
  const AlbumGrid({required this.albums, required this.onOpen, super.key});

  final List<Album> albums;
  final void Function(Album album) onOpen;

  static const double _gutter = AppSpacing.md;

  @override
  Widget build(BuildContext context) {
    final double labelExtent = AlbumGridCard.labelExtent(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double content = constraints.maxWidth - _gutter * 2;
        final int columns = albumGridColumnCount(content);
        final double cardWidth = (content - _gutter * (columns - 1)) / columns;
        return GridView.builder(
          key: const Key('library_album_grid'),
          padding: const EdgeInsets.all(_gutter),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: _gutter,
            mainAxisSpacing: AppSpacing.lg,
            mainAxisExtent: cardWidth + labelExtent,
          ),
          itemCount: albums.length,
          itemBuilder: (BuildContext context, int index) {
            final Album album = albums[index];
            return AlbumGridCard(
              album: album,
              onTap: () => onOpen(album),
            );
          },
        );
      },
    );
  }
}
