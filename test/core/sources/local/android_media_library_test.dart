import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/local/android_media_library.dart';
import 'package:linthra/core/sources/local/folder_location.dart';
import 'package:linthra/core/sources/local/local_audio_metadata.dart';
import 'package:linthra/core/sources/local/local_music_source.dart';
import 'package:linthra/core/sources/local/method_channel_android_media_library.dart';
import 'package:linthra/core/sources/local/saf_document_lister.dart';

class _FakeAndroidMediaLibrary implements AndroidMediaLibrary {
  const _FakeAndroidMediaLibrary({required this.result});

  final SafScanResult result;

  @override
  Future<SafScanResult> listDeviceAudio() async => result;

  @override
  Future<void> openAppSettings() async {}

  @override
  Future<AndroidMusicPermissionStatus> permissionStatus() async =>
      AndroidMusicPermissionStatus.allowed;

  @override
  Future<AndroidMusicPermissionStatus> requestPermission() async =>
      AndroidMusicPermissionStatus.allowed;
}

void main() {
  group('Android device-wide local music', () {
    test('MediaStore sentinel is not treated as a filesystem path', () {
      final FolderLocation location =
          FolderLocation.parse(FolderLocation.androidMediaStoreAudio);

      expect(location.isAndroidMediaStore, isTrue);
      expect(location.isFilesystemPath, isFalse);
      expect(location.isContentUri, isFalse);
      expect(location.displayLabel, 'All music on this device');
    });

    test('permission status wire values are conservative', () {
      expect(
        MethodChannelAndroidMediaLibrary.parsePermissionStatus('allowed'),
        AndroidMusicPermissionStatus.allowed,
      );
      expect(
        MethodChannelAndroidMediaLibrary.parsePermissionStatus('denied'),
        AndroidMusicPermissionStatus.denied,
      );
      expect(
        MethodChannelAndroidMediaLibrary.parsePermissionStatus('notRequested'),
        AndroidMusicPermissionStatus.notRequested,
      );
      expect(
        MethodChannelAndroidMediaLibrary.parsePermissionStatus('unexpected'),
        AndroidMusicPermissionStatus.unavailable,
      );
    });

    test('MediaStore rows use the existing local track mapper', () async {
      final LocalMusicSource source = LocalMusicSource(
        folderPath: FolderLocation.androidMediaStoreAudio,
        androidMediaLibrary: _FakeAndroidMediaLibrary(
          result: SafScanResult(
            documents: <SafAudioDocument>[
              SafAudioDocument(
                uri: 'content://media/external/audio/media/42',
                name: '03 - Fallback.mp3',
                mimeType: 'audio/mpeg',
                metadata: const LocalAudioMetadata(
                  title: 'Tagged title',
                  artist: 'Artist',
                  album: 'Album',
                  trackNumber: 3,
                  duration: Duration(seconds: 123),
                ),
              ),
            ],
            filesVisited: 1,
          ),
        ),
      );

      final LocalScan scan = await source.scanTracks();

      expect(scan.tracks, hasLength(1));
      expect(scan.tracks.single.uri, 'content://media/external/audio/media/42');
      expect(scan.tracks.single.title, 'Tagged title');
      expect(scan.tracks.single.artistName, 'Artist');
      expect(scan.tracks.single.albumName, 'Album');
      expect(scan.tracks.single.trackNumber, 3);
      expect(scan.tracks.single.duration, const Duration(seconds: 123));
      expect(scan.report.importedTracks, 1);
      expect(scan.report.isContentUri, isFalse);
    });
  });
}
