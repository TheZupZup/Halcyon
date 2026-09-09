import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Persists a local file's embedded cover art (ID3 `APIC`, a FLAC `PICTURE`
/// block, an MP4 `covr` atom, …) into Linthra's private, OS-reclaimable cache
/// and hands back a `file:` URI that [Track.artworkUri] can point at directly
/// — [artworkImageProvider] already loads a `file:` URI straight off disk, so
/// nothing downstream needs to know this cover came from a local file's own
/// tags rather than a server.
///
/// Mirrors the Android SAF walk's own embedded-artwork cache
/// (`SafDocumentScanner.cacheEmbeddedArtwork`): extract once, key by a hash of
/// the *source file's path* (never the path itself, see [_key]) so a rescan
/// reuses what an earlier one already extracted, write through a temp sibling
/// then rename so a crash mid-write can never leave a half-written cover that
/// fails to decode forever, and treat every failure as "no artwork" rather
/// than a failed scan or a dropped track.
///
/// Distinct from [ArtworkDiskCache] (remote covers, keyed by URL, never
/// resized — a server already serves a sane size) and [MediaArtworkCache] (a
/// bounded copy of *whichever* cover for the platform media session): this is
/// the one path from a local file's own embedded picture to something
/// Linthra's UI can render.
///
/// A cover wider or taller than [_maxDimension] is downsampled before it ever
/// reaches disk. An embedded scan can be a multi-megapixel JPEG nobody asked
/// to see at full resolution, and every track row in a scrolling list would
/// otherwise decode it in full just to paint a thumbnail a hundred pixels
/// wide.
class LocalArtworkCache {
  LocalArtworkCache({Future<Directory> Function()? directory})
      : _directory = directory ?? _defaultDirectory;

  final Future<Directory> Function() _directory;

  /// The long edge a cached cover is bounded to. Large enough for every
  /// surface Linthra renders a cover at, including the full-screen Now
  /// Playing background; small enough that a 4000x4000 embedded scan never
  /// sits in memory or on disk at full size just for a list thumbnail.
  static const int _maxDimension = 1024;

  /// The already-cached cover for [path]'s source file, or `null` on a miss —
  /// including a missing, empty, or otherwise unreadable cache entry, which is
  /// treated exactly like a miss so a later [store] regenerates it safely.
  Future<File?> cachedFile(String path) async {
    final File file = await _fileFor(path);
    try {
      if (await file.length() > 0) return file;
    } on FileSystemException {
      // Missing, or an odd permissions error — either way, not a usable hit.
    }
    return null;
  }

  /// Bounds a just-extracted embedded picture's [bytes] and writes it to the
  /// private cache for [path]'s source file, returning a `file:` URI to it.
  /// Returns `null` — and writes nothing — when [bytes] is empty or the image
  /// can't be decoded at all (a corrupt or unsupported embedded picture);
  /// never throws.
  Future<Uri?> store(String path, Uint8List bytes) async {
    if (bytes.isEmpty) return null;
    try {
      final Uint8List? bounded = await _bound(bytes);
      if (bounded == null) return null;
      final File file = await _fileFor(path);
      final Directory dir = file.parent;
      if (!await dir.exists()) await dir.create(recursive: true);
      // Temp sibling then rename: an interrupted write can never leave a
      // truncated cover that then fails to decode forever.
      final File tmp = File('${file.path}.tmp');
      await tmp.writeAsBytes(bounded, flush: true);
      await tmp.rename(file.path);
      return Uri.file(file.path);
    } catch (_) {
      return null;
    }
  }

  Future<File> _fileFor(String path) async {
    final Directory dir = await _directory();
    return File(p.join(dir.path, '${_key(path)}.img'));
  }

  /// A stable, path-free cache key: the SHA-256 of the source file's own path.
  /// Hashing keeps a user's real file path (private — see CONTRIBUTING,
  /// Privacy) out of both the file name and the cache directory listing,
  /// mirroring the SHA-1-of-content-URI key the Android SAF walk uses for the
  /// same purpose.
  static String _key(String path) =>
      sha256.convert(utf8.encode(path)).toString();

  /// Downsamples [bytes] to at most [_maxDimension] on its long edge,
  /// preserving aspect ratio, or returns it unchanged when already within
  /// bounds — a resize would only cost a decode/re-encode for no benefit.
  /// Returns `null` when the bytes can't be decoded as an image at all, so the
  /// caller never caches something nothing could ever render anyway.
  Future<Uint8List?> _bound(Uint8List bytes) async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Image? image;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final int width = descriptor.width;
      final int height = descriptor.height;
      if (width <= _maxDimension && height <= _maxDimension) return bytes;

      final double scale = _maxDimension / (width > height ? width : height);
      final ui.Codec codec = await descriptor.instantiateCodec(
        targetWidth: (width * scale).round().clamp(1, width),
        targetHeight: (height * scale).round().clamp(1, height),
      );
      final ui.FrameInfo frame = await codec.getNextFrame();
      codec.dispose();
      image = frame.image;
      final ByteData? data =
          await image.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List();
    } catch (_) {
      return null;
    } finally {
      image?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  static Future<Directory> _defaultDirectory() async {
    final Directory base = await getApplicationCacheDirectory();
    return Directory(p.join(base.path, 'local_artwork_cache'));
  }
}
