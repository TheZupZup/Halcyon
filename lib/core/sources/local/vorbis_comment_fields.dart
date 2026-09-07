import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Reads Vorbis comments out of a FLAC file *with their field names intact*.
///
/// `audio_metadata_reader` folds `ARTIST` and `ALBUMARTIST` into one list
/// (`vorbis_comment.dart`: `case 'ARTIST' || "ALBUMARTIST"`), which loses the
/// only thing that tells a compilation's performer from its album name. No
/// heuristic recovers it: `[Alice, Bob]` is two `ARTIST` values on a
/// collaboration, `[Guest, Various Artists]` is `ARTIST` plus `ALBUMARTIST`,
/// and from the merged list those are the same shape. So this reads the block
/// directly rather than guessing.
///
/// FLAC only, deliberately. Its metadata blocks sit in the clear right after
/// the magic, so this is a short, well-specified read. OGG and Opus carry the
/// same comments inside Ogg pages, which needs page and packet framing for a
/// far less common local format; those keep the conservative path in
/// [FilesystemLocalMetadataReader] instead.
///
/// Deliberately total: a non-FLAC file, a truncated header, a declared length
/// that runs past the file, or invalid UTF-8 all return null so the caller
/// falls back. It never throws and never logs the path.
class VorbisCommentFields {
  const VorbisCommentFields._();

  /// A sanity bound on the comment block itself, so a corrupt 24-bit length
  /// cannot ask for an arbitrary allocation. Real comment blocks are a few KiB;
  /// this is not a bound on the metadata ahead of it, which is seeked past.
  static const int _maxCommentBlockBytes = 1 << 20; // 1 MiB

  /// Comments keyed by upper-cased field name, or null when [file] is not a
  /// FLAC whose comment block could be read.
  ///
  /// Values keep their order and their duplicates: `ARTIST=Alice`,
  /// `ARTIST=Bob` yields `{'ARTIST': ['Alice', 'Bob']}`, which is the spec's
  /// way of writing a collaboration.
  ///
  /// Walks the block chain and *seeks* past everything that is not the comment
  /// block, rather than reading a fixed prefix. FLAC puts no ordering
  /// requirement on metadata blocks, and a file with embedded cover art carries
  /// a PICTURE block that is routinely megabytes; reading a fixed prefix would
  /// silently miss the comments on exactly those files and fall back to the
  /// package's merged list. Only the comment block is ever read into memory,
  /// never the art and never the audio.
  static Future<Map<String, List<String>>?> read(File file) async {
    RandomAccessFile? handle;
    try {
      handle = await file.open();
      final Uint8List magic = await handle.read(4);
      if (!_isFlac(magic)) return null;

      while (true) {
        final Uint8List header = await handle.read(4);
        if (header.length < 4) return null; // truncated
        final bool isLast = (header[0] & 0x80) != 0;
        final int type = header[0] & 0x7F;
        final int length = (header[1] << 16) | (header[2] << 8) | header[3];

        if (type == _vorbisCommentBlock) {
          if (length > _maxCommentBlockBytes) return null;
          final Uint8List block = await handle.read(length);
          if (block.length < length) return null; // truncated
          return _parseComments(block);
        }
        if (isLast) return null; // no comment block in this file
        await handle.setPosition(await handle.position() + length);
      }
    } on FileSystemException {
      return null;
    } finally {
      await handle?.close();
    }
  }

  static const int _vorbisCommentBlock = 4;

  static bool _isFlac(Uint8List bytes) =>
      bytes.length >= 4 &&
      bytes[0] == 0x66 && // f
      bytes[1] == 0x4C && // L
      bytes[2] == 0x61 && // a
      bytes[3] == 0x43; // C

  /// The parsing half, separated so it is testable on bytes alone.
  ///
  /// FLAC layout: `fLaC`, then metadata blocks, each a header byte (the top bit
  /// marks the last block, the low seven the type) plus a 24-bit big-endian
  /// length, then that many bytes. Type 4 is VORBIS_COMMENT, whose payload is
  /// little-endian: vendor length, vendor, comment count, then each comment as
  /// a length and `FIELD=value` in UTF-8.
  static Map<String, List<String>>? parse(Uint8List bytes) {
    if (!_isFlac(bytes)) return null;

    int offset = 4;
    while (offset + 4 <= bytes.length) {
      final int header = bytes[offset];
      final bool isLast = (header & 0x80) != 0;
      final int type = header & 0x7F;
      final int length = (bytes[offset + 1] << 16) |
          (bytes[offset + 2] << 8) |
          bytes[offset + 3];
      final int start = offset + 4;
      final int end = start + length;
      // A block that runs past what was read is not something to guess at.
      if (end > bytes.length) return null;
      if (type == _vorbisCommentBlock) {
        return _parseComments(Uint8List.sublistView(bytes, start, end));
      }
      if (isLast) return null;
      offset = end;
    }
    return null;
  }

  static Map<String, List<String>>? _parseComments(Uint8List block) {
    int offset = 0;

    int? readUint32le() {
      if (offset + 4 > block.length) return null;
      final int value = block[offset] |
          (block[offset + 1] << 8) |
          (block[offset + 2] << 16) |
          (block[offset + 3] << 24);
      offset += 4;
      // A negative or absurd length is corruption, not a field.
      return value < 0 ? null : value;
    }

    final int? vendorLength = readUint32le();
    if (vendorLength == null || offset + vendorLength > block.length) {
      return null;
    }
    offset += vendorLength;

    final int? count = readUint32le();
    if (count == null) return null;

    final Map<String, List<String>> fields = <String, List<String>>{};
    for (int i = 0; i < count; i++) {
      final int? length = readUint32le();
      if (length == null || offset + length > block.length) return null;
      final Uint8List raw =
          Uint8List.sublistView(block, offset, offset + length);
      offset += length;
      final String comment;
      try {
        comment = utf8.decode(raw);
      } on FormatException {
        // One unreadable comment must not cost the rest of the block.
        continue;
      }
      final int equals = comment.indexOf('=');
      if (equals <= 0) continue;
      final String name = comment.substring(0, equals).toUpperCase();
      final String value = comment.substring(equals + 1);
      (fields[name] ??= <String>[]).add(value);
    }
    return fields;
  }
}
