import 'dart:io';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';

import 'local_audio_metadata.dart';
import 'local_metadata_reader.dart';
import 'vorbis_comment_fields.dart';

/// Reads audio tags from a real file on disk: the desktop/Linux half of
/// [LocalMetadataReader], where Android's SAF walk reads them natively.
///
/// Without this, a Linux library shows filenames and folder names: the mapper's
/// fallback is deliberately decent, but "03 - Track.flac" in a folder called
/// "Album" is not the same as a real title, artist and duration. This is what
/// makes a local Linux library look like a library (#407).
///
/// It reads through `audio_metadata_reader` (MIT, pure Dart), which opens the
/// file and parses only the tag structures (headers, frames, comment blocks)
/// rather than reading a whole 60 MB FLAC into memory to find its title. Cover
/// art is deliberately *not* fetched (`getImage: false`): embedded artwork is a
/// separate concern (#408) and pulling multi-megabyte images out of every file
/// during a scan is exactly the cost this avoids.
///
/// Deliberately total, like the SAF reader it mirrors: an unreadable file, an
/// unsupported container, a truncated tag or a format the package has no parser
/// for all return `null`, so the track still appears with its filename-derived
/// metadata instead of vanishing from the library.
class FilesystemLocalMetadataReader implements LocalMetadataReader {
  const FilesystemLocalMetadataReader();

  @override
  Future<LocalAudioMetadata?> readFromPath(String path) async {
    try {
      final File file = File(path);
      // `await`, and asynchronous `exists()` rather than `existsSync()`, is
      // load-bearing: it is the only point in this method that reaches the
      // event loop. `readAllMetadata` below is synchronous, so without a real
      // asynchronous call first, this method would do all its work before
      // returning an already-completed Future. A caller awaiting that gets a
      // microtask, and the microtask queue drains completely before the event
      // loop runs again, so a scan of thousands of files would be one
      // unbroken chain with no frame rendered and no input handled from the
      // first file to the last. Measured on a 2000-iteration stand-in: zero
      // event-loop ticks with the synchronous check, one per file with this.
      // Switching this back to existsSync() re-freezes the desktop UI for the
      // length of the scan, silently (see the test that asserts the yield).
      if (!await file.exists()) return null;
      // Format-specific rather than the package's unified `readMetadata`: that
      // one folds ID3's TPE2 (album artist) into a single `artist` field, which
      // would lose the distinction the catalog groups albums by.
      final LocalAudioMetadata? parsed =
          _fromParserTag(readAllMetadata(file, getImage: false));
      if (parsed == null) return null;
      // FLAC's comment block is readable in the clear, so prefer the real
      // ARTIST/ALBUMARTIST over what the package merged. See
      // [VorbisCommentFields] for why no heuristic can substitute for this.
      return _withVorbisArtists(parsed, await VorbisCommentFields.read(file));
    } catch (_) {
      // Any failure is "no tags", never a failed scan. The path is not logged:
      // a user's file path is private data (see CONTRIBUTING, Privacy).
      return null;
    }
  }

  /// Replaces the artist fields with the file's real ones when the comment
  /// block could be read with its field names intact.
  ///
  /// [fields] is null for every non-FLAC container (and for an unreadable
  /// block), in which case [metadata] keeps whatever the package's merged list
  /// produced. `ARTIST` values are joined because the spec's way to write a
  /// collaboration is to repeat the field; `ALBUMARTIST` takes the first, since
  /// an album has one.
  static LocalAudioMetadata _withVorbisArtists(
    LocalAudioMetadata metadata,
    Map<String, List<String>>? fields,
  ) {
    if (fields == null) return metadata;
    final List<String> artists = _nonBlank(fields['ARTIST']);
    final List<String> albumArtists = _nonBlank(fields['ALBUMARTIST']);
    return LocalAudioMetadata(
      title: metadata.title,
      artist: artists.isEmpty ? null : artists.join(', '),
      albumArtist: albumArtists.firstOrNull,
      album: metadata.album,
      albumId: metadata.albumId,
      trackNumber: metadata.trackNumber,
      duration: metadata.duration,
      artworkUri: metadata.artworkUri,
    );
  }

  static List<String> _nonBlank(List<String>? values) => <String>[
        for (final String value in values ?? const <String>[])
          if (value.trim().isNotEmpty) value.trim(),
      ];

  /// The track artist from Vorbis's merged ARTIST/ALBUMARTIST list, or null
  /// when the entries disagree. Only OGG and Opus reach this: FLAC's real field
  /// names are read instead (see [VorbisCommentFields]).
  ///
  /// Vorbis comments carry no ordering requirement, and the package folds both
  /// tags into one list in file order, so `first` is whichever the tagger
  /// happened to write first. On a compilation (`ARTIST=Featured Guest`,
  /// `ALBUMARTIST=Various Artists`) that means the same file reports the
  /// performer or the compilation name depending on the tool that wrote it,
  /// verified against fixtures written both ways.
  ///
  /// The distinction only matters when the values actually differ. A normal
  /// album tags both with the same name, so the list is one repeated value and
  /// there is nothing to guess; that is the common case and it is answered
  /// exactly. When they disagree this returns null rather than a coin flip, and
  /// the mapper falls back to the filename and folder: absent beats wrong half
  /// the time. It cannot do better, because two distinct entries are equally
  /// consistent with a collaboration (two ARTIST fields) and a compilation
  /// (ARTIST plus ALBUMARTIST), the case FLAC no longer has to guess at.
  static String? _unambiguousArtist(List<String> merged) {
    final Set<String> distinct = <String>{
      for (final String value in merged)
        if (value.trim().isNotEmpty) value.trim(),
    };
    return distinct.length == 1 ? distinct.first : null;
  }

  /// Maps one parsed container to Linthra's source-agnostic holder.
  ///
  /// Only the fields the catalog can actually store are mapped. The package
  /// also exposes disc number, year and genre, which `Track` has nowhere to put
  /// today. Surfacing those needs a catalog/schema change, so they are left
  /// unread rather than parsed into a field nothing reads.
  ///
  /// Typed as [Object] on purpose: the package's common supertype (`ParserTag`)
  /// lives under `src/` and is not exported, and reaching into another
  /// package's private library to name it would be worse than matching the
  /// public container types directly.
  static LocalAudioMetadata? _fromParserTag(Object tag) {
    return switch (tag) {
      // ID3: TIT2 / TPE1 / TPE2 / TALB. The one format where the track artist
      // and the album artist are unambiguously separate.
      Mp3Metadata() => _metadata(
          title: tag.songName,
          artist: tag.leadPerformer,
          albumArtist: tag.bandOrOrchestra,
          album: tag.album,
          trackNumber: tag.trackNumber,
          duration: tag.duration,
        ),
      // APEv2 names its album artist outright.
      ApeMetadata() => _metadata(
          title: tag.title,
          artist: tag.artist,
          albumArtist: tag.albumArtist,
          album: tag.album,
          trackNumber: tag.trackNumber,
          duration: tag.duration,
        ),
      // Vorbis comments (FLAC, OGG, Opus). The package appends both ARTIST and
      // ALBUMARTIST to one list (`case 'ARTIST' || "ALBUMARTIST"`), discarding
      // which was which. The artist here is therefore provisional: for FLAC,
      // readFromPath replaces it (and fills the album artist) from the real
      // field names via [VorbisCommentFields]. OGG and Opus keep what
      // [_unambiguousArtist] can salvage and report no album artist, which lets
      // the mapper group on album + artist the same way the Subsonic source
      // handles a server with no trustworthy per-song album artist.
      VorbisMetadata() => _metadata(
          title: tag.title.firstOrNull,
          artist: _unambiguousArtist(tag.artist),
          album: tag.album.firstOrNull,
          trackNumber: tag.trackNumber.firstOrNull,
          duration: tag.duration,
        ),
      // iTunes-style atoms. The package does not read `aART`, so no album
      // artist.
      Mp4Metadata() => _metadata(
          title: tag.title,
          artist: tag.artist,
          album: tag.album,
          trackNumber: tag.trackNumber,
          duration: tag.duration,
        ),
      // RIFF INFO chunks (WAV), which have no album-artist concept at all.
      RiffMetadata() => _metadata(
          title: tag.title,
          artist: tag.artist,
          album: tag.album,
          trackNumber: tag.trackNumber,
          duration: tag.duration,
        ),
      _ => null,
    };
  }

  /// Builds the holder, or null when the file carried nothing usable.
  ///
  /// Blank and whitespace-only tags (common in files written by sloppy
  /// taggers) are normalized to absent here so the mapper's filename fallback wins
  /// instead of a track showing an empty title. A non-positive track number is
  /// meaningless as an index and folds to null the same way.
  static LocalAudioMetadata? _metadata({
    String? title,
    String? artist,
    String? albumArtist,
    String? album,
    int? trackNumber,
    Duration? duration,
  }) {
    final LocalAudioMetadata metadata = LocalAudioMetadata(
      title: _blankToNull(title),
      artist: _blankToNull(artist),
      albumArtist: _blankToNull(albumArtist),
      album: _blankToNull(album),
      trackNumber:
          (trackNumber != null && trackNumber > 0) ? trackNumber : null,
      duration:
          (duration != null && duration > Duration.zero) ? duration : null,
    );
    return metadata.isEmpty ? null : metadata;
  }

  static String? _blankToNull(String? value) {
    if (value == null) return null;
    final String trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
