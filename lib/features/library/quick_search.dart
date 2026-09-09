import 'package:flutter/foundation.dart';

import '../../core/catalog/text_folding.dart';
import '../../core/models/album.dart';
import '../../core/models/artist.dart';
import '../../core/models/playlist.dart';
import '../../core/models/track.dart';

/// Pure, dependency-free ranking for the desktop quick-search overlay.
///
/// This is the Library search box's sibling, not a replacement: `library_search`
/// *filters* one tab's list, while this *ranks and caps* across all four kinds
/// at once so the overlay can show the few best answers without scrolling. Both
/// fold through [foldText], so "beyonce" still finds "Beyoncé" here too.
///
/// It stays a pure function over lists the caller already has (the unified
/// catalog, the derived albums/artists, the user's playlists) so quick search
/// never builds a second catalog of its own, and so the ranking is unit-testable
/// without a widget, a repository, or a provider container.

/// How many results one group shows. The overlay is a shortlist, not a browse
/// surface: past a handful of rows per kind, scanning them with the eye is
/// slower than pressing another key, and the full list is one Enter away on the
/// Library screen.
const int kQuickSearchGroupLimit = 5;

/// The four kinds of thing quick search can find, in the order the overlay
/// renders their groups.
enum QuickSearchKind {
  song('Songs'),
  album('Albums'),
  artist('Artists'),
  playlist('Playlists');

  const QuickSearchKind(this.label);

  /// The group heading shown above this kind's results.
  final String label;
}

/// One result row. Sealed so every consumer (the overlay's rendering and its
/// activation) has to handle all four kinds — adding a fifth becomes a compile
/// error rather than a silently dead row.
@immutable
sealed class QuickSearchResult {
  const QuickSearchResult();

  QuickSearchKind get kind;

  /// Stable identity for the underlying item, used as a widget key so a
  /// re-ranked list does not reuse another row's state.
  String get id;

  /// The primary line shown in the overlay.
  String get title;

  /// The secondary line, or `null` when the item carries nothing useful.
  String? get subtitle;
}

/// A song. Carries the unified (displayed) [Track], so activating it plays the
/// same copy the Library screen would have played.
class QuickSearchSong extends QuickSearchResult {
  const QuickSearchSong(this.track);

  final Track track;

  @override
  QuickSearchKind get kind => QuickSearchKind.song;

  @override
  String get id => track.uri;

  @override
  String get title => track.title;

  @override
  String? get subtitle {
    final String label = track.artistAlbumLabel;
    return label.isEmpty ? null : label;
  }
}

/// An album, identified by the derived album id the album detail route takes.
class QuickSearchAlbum extends QuickSearchResult {
  const QuickSearchAlbum(this.album);

  final Album album;

  @override
  QuickSearchKind get kind => QuickSearchKind.album;

  @override
  String get id => album.id;

  @override
  String get title => album.title;

  @override
  String? get subtitle => album.artistName;
}

/// An artist, identified by the derived artist id the artist detail route takes.
class QuickSearchArtist extends QuickSearchResult {
  const QuickSearchArtist(this.artist);

  final Artist artist;

  @override
  QuickSearchKind get kind => QuickSearchKind.artist;

  @override
  String get id => artist.id;

  @override
  String get title => artist.name;

  @override
  String? get subtitle {
    final int albums = artist.albumCount;
    final int tracks = artist.trackCount;
    if (albums == 0 && tracks == 0) return null;
    return '${albums == 1 ? '1 album' : '$albums albums'} • '
        '${tracks == 1 ? '1 song' : '$tracks songs'}';
  }
}

/// A user playlist. Local-only playlists have no server tag; a synced one shows
/// which server it mirrors, exactly as the Playlists tab does.
class QuickSearchPlaylist extends QuickSearchResult {
  const QuickSearchPlaylist(this.playlist);

  final Playlist playlist;

  @override
  QuickSearchKind get kind => QuickSearchKind.playlist;

  @override
  String get id => playlist.id;

  @override
  String get title => playlist.name;

  @override
  String? get subtitle {
    final String count =
        playlist.length == 1 ? '1 song' : '${playlist.length} songs';
    final String? server = playlist.source.serverLabel;
    return server == null ? count : '$count • $server';
  }
}

/// The grouped, capped outcome of one query.
///
/// [rows] is the same results flattened in group order, which is what arrow-key
/// navigation walks: keeping one canonical order here means the overlay can
/// never highlight a row the list does not render.
@immutable
class QuickSearchResults {
  const QuickSearchResults({
    required this.groups,
    required this.rows,
  });

  static const QuickSearchResults empty = QuickSearchResults(
    groups: <QuickSearchKind, List<QuickSearchResult>>{},
    rows: <QuickSearchResult>[],
  );

  /// Non-empty groups only, in [QuickSearchKind] declaration order.
  final Map<QuickSearchKind, List<QuickSearchResult>> groups;

  /// Every result, group by group, in render order.
  final List<QuickSearchResult> rows;

  bool get isEmpty => rows.isEmpty;

  bool get isNotEmpty => rows.isNotEmpty;
}

/// Ranks and caps [tracks], [albums], [artists] and [playlists] against [query].
///
/// An empty (or whitespace-only) query returns [QuickSearchResults.empty]: the
/// overlay opens on a prompt, not on the entire library. Each group keeps its
/// best [limit] matches; within a group, results are ordered by [_score] and
/// ties fall back to catalog order, so the same library and query always
/// produce the same list.
QuickSearchResults runQuickSearch({
  required String query,
  List<Track> tracks = const <Track>[],
  List<Album> albums = const <Album>[],
  List<Artist> artists = const <Artist>[],
  List<Playlist> playlists = const <Playlist>[],
  int limit = kQuickSearchGroupLimit,
}) {
  final String folded = foldText(query);
  if (folded.isEmpty) return QuickSearchResults.empty;

  final Map<QuickSearchKind, List<QuickSearchResult>> groups =
      <QuickSearchKind, List<QuickSearchResult>>{};

  void addGroup(QuickSearchKind kind, List<QuickSearchResult> results) {
    if (results.isNotEmpty) groups[kind] = results;
  }

  addGroup(
    QuickSearchKind.song,
    _rank<Track>(
      tracks,
      folded,
      limit,
      // A song matches on its own title first; artist and album still match, but
      // rank below a title hit so typing an album name does not bury the song
      // actually called that.
      fields: (Track t) =>
          <String?>[t.title, t.artistName, t.albumName, t.albumArtistName],
      toResult: QuickSearchSong.new,
    ),
  );
  addGroup(
    QuickSearchKind.album,
    _rank<Album>(
      albums,
      folded,
      limit,
      fields: (Album a) => <String?>[a.title, a.artistName],
      toResult: QuickSearchAlbum.new,
    ),
  );
  addGroup(
    QuickSearchKind.artist,
    _rank<Artist>(
      artists,
      folded,
      limit,
      fields: (Artist a) => <String?>[a.name],
      toResult: QuickSearchArtist.new,
    ),
  );
  addGroup(
    QuickSearchKind.playlist,
    _rank<Playlist>(
      playlists,
      folded,
      limit,
      fields: (Playlist p) => <String?>[p.name, p.description],
      toResult: QuickSearchPlaylist.new,
    ),
  );

  return QuickSearchResults(
    groups: Map<QuickSearchKind, List<QuickSearchResult>>.unmodifiable(groups),
    rows: List<QuickSearchResult>.unmodifiable(<QuickSearchResult>[
      for (final QuickSearchKind kind in QuickSearchKind.values)
        ...?groups[kind],
    ]),
  );
}

/// Scores every item that matches, keeps the best [limit], and maps them to
/// results.
///
/// One pass over the source list, holding only the [limit] best rows seen so
/// far, so a one-letter query over a 50 000-track library costs a scan and a
/// handful of comparisons rather than scoring, collecting and sorting every
/// match. Ties break on catalog position, so the same library and query always
/// produce the exact same rows in the same order.
List<QuickSearchResult> _rank<T>(
  List<T> items,
  String foldedQuery,
  int limit, {
  required List<String?> Function(T item) fields,
  required QuickSearchResult Function(T item) toResult,
}) {
  if (limit <= 0) return const <QuickSearchResult>[];
  final List<_Scored<T>> best = <_Scored<T>>[];
  for (int i = 0; i < items.length; i++) {
    final T item = items[i];
    final int score = _score(fields(item), foldedQuery);
    if (score <= 0) continue;
    // Full and no better than the weakest kept row: nothing to do. Equal scores
    // lose here, which is the catalog-order tiebreak.
    if (best.length == limit && score <= best.last.score) continue;
    int at = best.length;
    while (at > 0 && best[at - 1].score < score) {
      at--;
    }
    best.insert(at, _Scored<T>(item, score));
    if (best.length > limit) best.removeLast();
  }
  if (best.isEmpty) return const <QuickSearchResult>[];
  return <QuickSearchResult>[
    for (final _Scored<T> scored in best) toResult(scored.item),
  ];
}

/// How well [fields] match [foldedQuery]; `0` means no match at all.
///
/// Earlier fields are worth more than later ones (a title hit beats an artist
/// hit), and within a field an exact value beats a prefix, which beats a match
/// at a word boundary, which beats a match anywhere. That ordering is what makes
/// typing three letters of a song you know put it on the first row.
int _score(List<String?> fields, String foldedQuery) {
  int best = 0;
  for (int i = 0; i < fields.length; i++) {
    final String? raw = fields[i];
    if (raw == null || raw.isEmpty) continue;
    final String folded = foldText(raw);
    if (!folded.contains(foldedQuery)) continue;

    final int quality;
    if (folded.length == foldedQuery.length) {
      quality = 4; // the whole value
    } else if (folded.startsWith(foldedQuery)) {
      quality = 3; // starts with the query
    } else if (_startsAnyWord(folded, foldedQuery)) {
      quality = 2; // starts a later word
    } else {
      quality = 1; // somewhere inside a word
    }

    // Field weight dominates quality, so a mid-word title hit still outranks an
    // exact artist hit — the field the user is most likely typing wins first.
    final int score = (fields.length - i) * 10 + quality;
    if (score > best) best = score;
  }
  return best;
}

/// Whether [query] begins any word of [text] — checked over every occurrence,
/// not just the first, so "ark" scores as a word start in "The Dark Ark" rather
/// than being judged on the mid-word hit that happens to come first.
bool _startsAnyWord(String text, String query) {
  int at = text.indexOf(query);
  while (at >= 0) {
    if (at > 0 && _wordSeparators.contains(text[at - 1])) return true;
    at = text.indexOf(query, at + 1);
  }
  return false;
}

/// The characters a word can start after. Deliberately a small, explicit set
/// rather than a regular expression: it runs once per candidate field on every
/// keystroke's worth of ranking.
const Set<String> _wordSeparators = <String>{
  ' ',
  '-',
  '_',
  '(',
  '[',
  '/',
  '.',
  ',',
  ':',
  "'",
  '"',
  '&',
};

/// An item paired with its score, so the sort never re-computes one.
class _Scored<T> {
  const _Scored(this.item, this.score);

  final T item;
  final int score;
}
