import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/services/local_artwork_cache.dart';

/// A real, decodable solid-colour PNG of [width]x[height] — a corrupt/garbage
/// byte string can stand in for "not an image", but bounding/resizing needs a
/// container [LocalArtworkCache]'s decoder can actually walk.
Future<Uint8List> _solidPng(int width, int height) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final ui.Canvas canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xFFAA5533),
  );
  final ui.Image image = await recorder.endRecording().toImage(width, height);
  final ByteData? data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

Future<ui.Size> _decodedSize(Uint8List bytes) async {
  final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(
    bytes,
  );
  final ui.ImageDescriptor descriptor = await ui.ImageDescriptor.encoded(
    buffer,
  );
  final ui.Size size =
      ui.Size(descriptor.width.toDouble(), descriptor.height.toDouble());
  descriptor.dispose();
  buffer.dispose();
  return size;
}

void main() {
  late Directory dir;
  late LocalArtworkCache cache;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('local_artwork_cache_test');
    cache = LocalArtworkCache(directory: () async => dir);
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('a fresh path has no cached file', () async {
    expect(await cache.cachedFile('/music/song.flac'), isNull);
  });

  test('store writes the image and cachedFile then finds it', () async {
    final Uint8List cover = await _solidPng(32, 32);

    final Uri? uri = await cache.store('/music/song.flac', cover);

    expect(uri, isNotNull);
    expect(uri!.isScheme('file'), isTrue);
    final File? found = await cache.cachedFile('/music/song.flac');
    expect(found, isNotNull);
    expect(found!.path, uri.toFilePath());
    expect(found.lengthSync(), greaterThan(0));
  });

  test('different source paths cache to different files', () async {
    final Uint8List cover = await _solidPng(16, 16);
    final Uri? a = await cache.store('/music/a.flac', cover);
    final Uri? b = await cache.store('/music/b.flac', cover);

    expect(a, isNotNull);
    expect(b, isNotNull);
    expect(a, isNot(b));
  });

  test('the cache key never contains the source path', () async {
    final Uint8List cover = await _solidPng(16, 16);
    await cache.store('/home/alice/Music/Private Folder/song.flac', cover);

    final List<FileSystemEntity> written = dir.listSync();
    expect(written, hasLength(1));
    expect(written.single.path.contains('alice'), isFalse);
    expect(written.single.path.contains('Private'), isFalse);
  });

  test('store returns null and writes nothing for empty bytes', () async {
    final Uri? uri = await cache.store('/music/song.flac', Uint8List(0));

    expect(uri, isNull);
    expect(dir.listSync(), isEmpty);
  });

  test('store returns null for bytes that are not a decodable image', () async {
    final Uri? uri = await cache.store(
      '/music/song.flac',
      Uint8List.fromList('definitely not an image'.codeUnits),
    );

    expect(uri, isNull);
    expect(await cache.cachedFile('/music/song.flac'), isNull);
  });

  test('a corrupt (0-byte) cache entry is treated as a miss', () async {
    final Uint8List cover = await _solidPng(16, 16);
    final Uri uri = (await cache.store('/music/song.flac', cover))!;
    File(uri.toFilePath()).writeAsBytesSync(<int>[]);

    expect(await cache.cachedFile('/music/song.flac'), isNull);
  });

  test('an image within the bound is stored at its original size', () async {
    final Uint8List cover = await _solidPng(300, 150);

    final Uri uri = (await cache.store('/music/song.flac', cover))!;

    final ui.Size size = await _decodedSize(
      File(uri.toFilePath()).readAsBytesSync(),
    );
    expect(size.width, 300);
    expect(size.height, 150);
  });

  test('an image over the bound is downsampled, aspect ratio kept', () async {
    final Uint8List cover = await _solidPng(4000, 2000);

    final Uri uri = (await cache.store('/music/song.flac', cover))!;

    final ui.Size size = await _decodedSize(
      File(uri.toFilePath()).readAsBytesSync(),
    );
    expect(size.width, lessThanOrEqualTo(1024));
    expect(size.height, lessThanOrEqualTo(1024));
    expect(size.width / size.height, closeTo(2.0, 0.05));
  });

  test('storing again for the same path overwrites the same cache entry',
      () async {
    final Uint8List small = await _solidPng(16, 16);
    final Uint8List big = await _solidPng(64, 64);
    final Uri first = (await cache.store('/music/song.flac', small))!;
    final Uri second = (await cache.store('/music/song.flac', big))!;

    expect(second, first);
    final ui.Size size = await _decodedSize(
      File(second.toFilePath()).readAsBytesSync(),
    );
    expect(size.width, 64);
  });
}
