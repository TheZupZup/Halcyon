import 'dart:convert';
import 'dart:typed_data';

/// Byte-level builders for small, real audio files carrying real tags.
///
/// The tag reader parses actual container structures, so testing it needs
/// actual containers. These build them from the format specs instead of
/// committing binary fixtures: a reviewer can see exactly which frame or
/// comment a test is claiming to write, and a fixture that drifts from the
/// spec fails the test rather than silently decoding to something else.
///
/// Each file is metadata plus the smallest plausible audio payload — a few
/// hundred bytes, not a real song.
abstract final class AudioTagFixtures {
  /// An MP3 carrying an ID3v2.3 tag.
  ///
  /// ID3v2.3 is the version practically every tagger writes. Frame layout is
  /// `TTTT` (id) + 4-byte big-endian size + 2 flag bytes + payload, and a text
  /// frame's payload starts with an encoding byte (`0x00` = ISO-8859-1). The
  /// tag's own size is *synchsafe*: 7 bits per byte, so a size byte can never
  /// look like an MPEG sync word.
  static Uint8List mp3({
    String? title,
    String? artist,
    String? albumArtist,
    String? album,
    String? track,
  }) {
    final BytesBuilder frames = BytesBuilder();
    void frame(String id, String? value) {
      if (value == null) return;
      final List<int> text = <int>[0x00, ...value.codeUnits];
      frames.add(id.codeUnits);
      frames.add(_uint32be(text.length));
      frames.add(<int>[0x00, 0x00]);
      frames.add(text);
    }

    frame('TIT2', title); // Title
    frame('TPE1', artist); // Lead performer — this track's artist
    frame('TPE2', albumArtist); // Band/orchestra — the album artist
    frame('TALB', album); // Album
    frame('TRCK', track); // Track number, possibly "3/12"

    final Uint8List body = frames.toBytes();
    final BytesBuilder file = BytesBuilder();
    file.add('ID3'.codeUnits);
    file.add(<int>[0x03, 0x00]); // v2.3.0
    file.add(<int>[0x00]); // no flags
    file.add(_synchsafe(body.length));
    file.add(body);
    file.add(_mpegFrames());
    return file.toBytes();
  }

  /// A FLAC carrying Vorbis comments.
  ///
  /// `fLaC`, then metadata blocks each headed by one byte (`last-block` flag in
  /// the top bit, block type in the low seven) and a 24-bit big-endian length.
  /// STREAMINFO (type 0) is mandatory and is where the duration comes from:
  /// total samples divided by sample rate.
  ///
  /// [albumArtistFirst] writes `ALBUMARTIST` ahead of `ARTIST`. Vorbis puts no
  /// ordering requirement on comments and real taggers differ, so a reader that
  /// depends on which one it meets first is wrong for half the files in the
  /// wild. Every other fixture here happens to write `ARTIST` first, which is
  /// exactly the bias that would let such a reader look correct.
  static Uint8List flac({
    String? title,
    String? artist,
    String? albumArtist,
    String? album,
    String? track,
    bool albumArtistFirst = false,
    int sampleRate = 44100,
    int totalSamples = 44100 * 3,
  }) {
    final List<String> artists = <String>[
      if (artist != null) 'ARTIST=$artist',
      if (albumArtist != null) 'ALBUMARTIST=$albumArtist',
    ];
    final List<String> comments = <String>[
      if (title != null) 'TITLE=$title',
      ...(albumArtistFirst ? artists.reversed : artists),
      if (album != null) 'ALBUM=$album',
      if (track != null) 'TRACKNUMBER=$track',
    ];

    final BytesBuilder vorbis = BytesBuilder();
    const String vendor = 'Linthra test fixture';
    vorbis.add(_uint32le(vendor.length));
    vorbis.add(vendor.codeUnits);
    vorbis.add(_uint32le(comments.length));
    for (final String comment in comments) {
      final List<int> bytes = _utf8(comment);
      vorbis.add(_uint32le(bytes.length));
      vorbis.add(bytes);
    }
    final Uint8List vorbisBlock = vorbis.toBytes();

    final BytesBuilder file = BytesBuilder();
    file.add('fLaC'.codeUnits);
    file.add(<int>[0x00]); // STREAMINFO, not the last block
    file.add(_uint24be(34));
    file.add(_streamInfo(sampleRate: sampleRate, totalSamples: totalSamples));
    file.add(<int>[0x84]); // VORBIS_COMMENT (4), last block
    file.add(_uint24be(vorbisBlock.length));
    file.add(vorbisBlock);
    return file.toBytes();
  }

  /// A WAV carrying RIFF `INFO` tags.
  ///
  /// `RIFF`/`WAVE`, a `fmt ` chunk (the byte rate in it is what the duration is
  /// derived from), a `LIST`/`INFO` chunk of four-character tags, then `data`.
  static Uint8List wav({
    String? title,
    String? artist,
    String? album,
    String? track,
    int sampleRate = 8000,
    int frames = 8000,
  }) {
    const int channels = 1;
    const int bytesPerSample = 2;
    final int byteRate = sampleRate * channels * bytesPerSample;
    final int dataSize = frames * channels * bytesPerSample;

    final BytesBuilder info = BytesBuilder();
    info.add('INFO'.codeUnits);
    void tag(String id, String? value) {
      if (value == null) return;
      // INFO values are NUL-terminated, and chunks are word-aligned.
      final List<int> bytes = <int>[...value.codeUnits, 0x00];
      info.add(id.codeUnits);
      info.add(_uint32le(bytes.length));
      info.add(bytes);
      if (bytes.length.isOdd) info.add(<int>[0x00]);
    }

    tag('INAM', title);
    tag('IART', artist);
    tag('IPRD', album);
    tag('ITRK', track);
    final Uint8List infoChunk = info.toBytes();

    final BytesBuilder fmt = BytesBuilder();
    fmt.add(_uint16le(1)); // PCM
    fmt.add(_uint16le(channels));
    fmt.add(_uint32le(sampleRate));
    fmt.add(_uint32le(byteRate));
    fmt.add(_uint16le(channels * bytesPerSample));
    fmt.add(_uint16le(bytesPerSample * 8));
    final Uint8List fmtChunk = fmt.toBytes();

    final BytesBuilder body = BytesBuilder();
    body.add('WAVE'.codeUnits);
    body.add('fmt '.codeUnits);
    body.add(_uint32le(fmtChunk.length));
    body.add(fmtChunk);
    body.add('LIST'.codeUnits);
    body.add(_uint32le(infoChunk.length));
    body.add(infoChunk);
    body.add('data'.codeUnits);
    body.add(_uint32le(dataSize));
    body.add(Uint8List(dataSize));
    final Uint8List bodyBytes = body.toBytes();

    final BytesBuilder file = BytesBuilder();
    file.add('RIFF'.codeUnits);
    file.add(_uint32le(bodyBytes.length));
    file.add(bodyBytes);
    return file.toBytes();
  }

  /// FLAC STREAMINFO: fixed 34 bytes, with the sample rate, channel count,
  /// bit depth and total sample count packed across a 64-bit field.
  static Uint8List _streamInfo({
    required int sampleRate,
    required int totalSamples,
  }) {
    final Uint8List block = Uint8List(34);
    final ByteData view = ByteData.sublistView(block);
    view.setUint16(0, 4096); // min block size
    view.setUint16(2, 4096); // max block size
    // min/max frame size stay zero ("unknown"), which is legal.

    // 20 bits sample rate, 3 bits (channels - 1), 5 bits (bits per sample - 1),
    // 36 bits total samples — 64 bits starting at byte 10.
    const int channels = 2;
    const int bitsPerSample = 16;
    final int high = (sampleRate << 12) |
        ((channels - 1) << 9) |
        ((bitsPerSample - 1) << 4) |
        ((totalSamples >> 32) & 0xF);
    view.setUint32(10, high);
    view.setUint32(14, totalSamples & 0xFFFFFFFF);
    return block;
  }

  /// A few MPEG-1 Layer III frames (sync word, 128 kbps, 44.1 kHz) of silence,
  /// so an MP3 fixture is a file a decoder can walk rather than a bare tag.
  ///
  /// More than one frame on purpose: a single frame leaves a demuxer seeking
  /// past the end of the file when it looks for the next sync word, and
  /// `ffprobe` rejects such a file outright. Three frames make the fixture
  /// something real tools accept.
  static Uint8List _mpegFrames({int count = 3}) {
    final BytesBuilder frames = BytesBuilder();
    for (int i = 0; i < count; i++) {
      frames.add(<int>[0xFF, 0xFB, 0x90, 0x00]);
      frames.add(Uint8List(413)); // 417-byte frame at 128 kbps / 44.1 kHz
    }
    return frames.toBytes();
  }

  static List<int> _uint32be(int value) => <int>[
        (value >> 24) & 0xFF,
        (value >> 16) & 0xFF,
        (value >> 8) & 0xFF,
        value & 0xFF,
      ];

  static List<int> _uint24be(int value) => <int>[
        (value >> 16) & 0xFF,
        (value >> 8) & 0xFF,
        value & 0xFF,
      ];

  static List<int> _uint32le(int value) => <int>[
        value & 0xFF,
        (value >> 8) & 0xFF,
        (value >> 16) & 0xFF,
        (value >> 24) & 0xFF,
      ];

  static List<int> _uint16le(int value) => <int>[
        value & 0xFF,
        (value >> 8) & 0xFF,
      ];

  /// ID3v2 sizes are synchsafe: seven significant bits per byte.
  static List<int> _synchsafe(int value) => <int>[
        (value >> 21) & 0x7F,
        (value >> 14) & 0x7F,
        (value >> 7) & 0x7F,
        value & 0x7F,
      ];

  static List<int> _utf8(String value) => utf8.encode(value);
}
