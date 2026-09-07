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
/// that runs past what was read, or invalid UTF-8 all return null so the caller
/// falls back. It never throws and never logs the path.
class VorbisCommentFields {
  const VorbisCommentFields._();

  /// Only the header region is read, never the audio. A file whose comment
  /// block does not start within this much is treated as unreadable rather than
  /// pulled into memory — the whole point of parsing tags instead of files.
  static const int _maxHeaderBytes = 1 << 20; // 1 MiB

  /// Comments keyed by upper-cased field name, or null when [file] is not a
  /// FLAC whose comment block could be read.
  ///
  /// Values keep their order and their duplicates: `ARTIST=Alice`,
  /// `ARTIST=Bob` yields `{'ARTIST': ['Alice', 'Bob']}`, which is the spec's
  /// way of writing a collaboration.
  static Future<Map<String, List<String>>?> read(File file) async {
    final Uint8List header;
    try {
      header = await _readHeader(file);
    } on FileSystemException {
      return null;
    }
    return parse(header);
  }

  static Future<Uint8List> _readHeader(File file) async {
    final RandomAccessFile handle = await file.open();
    try {
      final int length = await handle.length();
      final int wanted = length < _maxHeaderBytes ? length : _maxHeaderBytes;
      return await handle.read(wanted);
    } finally {
      await handle.close();
    }
  }

  /// The parsing half, separated so it is testable on bytes alone.
  ///
  /// FLAC layout: `fLaC`, then metadata blocks, each a header byte (the top bit
  /// marks the last block, the low seven the type) plus a 24-bit big-endian
  /// length, then that many bytes. Type 4 is VORBIS_COMMENT, whose payload is
  /// little-endian: vendor length, vendor, comment count, then each comment as
  /// a length and `FIELD=value` in UTF-8.
  static Map<String, List<String>>? parse(Uint8List bytes) {
    if (bytes.length < 4 ||
        bytes[0] != 0x66 || // f
        bytes[1] != 0x4C || // L
        bytes[2] != 0x61 || // a
        bytes[3] != 0x43) {
      return null;
    }

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
      if (type == 4) {
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
