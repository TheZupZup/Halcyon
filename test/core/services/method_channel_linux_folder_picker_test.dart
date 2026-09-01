import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/services/folder_picker_service.dart';
import 'package:linthra/core/services/linux_music_directory.dart';
import 'package:linthra/core/services/method_channel_linux_folder_picker.dart';

/// A fixed suggestion, so the argument the chooser is opened at is assertable
/// without reading the machine's real `user-dirs.dirs`.
class _FixedMusicDirectory implements LinuxMusicDirectory {
  const _FixedMusicDirectory(this.path);

  final String? path;

  @override
  Future<String?> resolve({
    HostPlatform? host,
    Map<String, String>? environment,
  }) async =>
      path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel =
      MethodChannel(MethodChannelLinuxFolderPicker.channelName);

  /// Installs a handler for the runner's channel and records what Dart sent.
  List<MethodCall> handleWith(Future<Object?> Function(MethodCall) handler) {
    final List<MethodCall> calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call);
      return handler(call);
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    return calls;
  }

  MethodChannelLinuxFolderPicker picker({
    HostPlatform host = HostPlatform.linux,
    String? suggested = '/home/me/Music',
  }) {
    return MethodChannelLinuxFolderPicker(
      host: host,
      suggestedDirectory: _FixedMusicDirectory(suggested),
    );
  }

  group('MethodChannelLinuxFolderPicker', () {
    test('returns the path the runner chose, and suggests a starting folder',
        () async {
      final List<MethodCall> calls =
          handleWith((_) async => '/home/me/Music/Albums');

      expect(await picker().pickFolder(), '/home/me/Music/Albums');
      expect(calls, hasLength(1));
      expect(
          calls.single.method, MethodChannelLinuxFolderPicker.pickFolderMethod);
      final Map<Object?, Object?> arguments =
          calls.single.arguments as Map<Object?, Object?>;
      expect(arguments['title'], MethodChannelLinuxFolderPicker.dialogTitle);
      expect(arguments['initialDirectory'], '/home/me/Music');
    });

    test('passes no starting folder when there is nothing to suggest',
        () async {
      // LinuxMusicDirectory fails safe to null; the chooser then opens wherever
      // the desktop (or the portal) would open it by default.
      final List<MethodCall> calls = handleWith((_) async => null);

      await picker(suggested: null).pickFolder();

      final Map<Object?, Object?> arguments =
          calls.single.arguments as Map<Object?, Object?>;
      expect(arguments['initialDirectory'], isNull);
    });

    test('returns null when the user cancels', () async {
      handleWith((_) async => null);

      expect(await picker().pickFolder(), isNull);
    });

    test('reports "no chooser here" off Linux, without touching the channel',
        () async {
      // Asserted with an injected host so the branch is reachable from any
      // machine. Nothing is sent: the channel only exists in the Linux runner.
      final List<MethodCall> calls = handleWith((_) async => '/should/not/run');

      await expectLater(
        picker(host: HostPlatform.android).pickFolder(),
        throwsA(isA<FolderPickerUnavailableException>()),
      );
      expect(calls, isEmpty);
    });

    test('reports "no chooser here" when the runner registered no handler',
        () async {
      // No mock handler installed: the platform channel answers with
      // MissingPluginException, which is an older/other runner, not a cancel.
      await expectLater(
        picker().pickFolder(),
        throwsA(isA<FolderPickerUnavailableException>()),
      );
    });

    test('reports "no chooser here" when GTK could not open a chooser',
        () async {
      handleWith((_) async {
        throw PlatformException(
          code: MethodChannelLinuxFolderPicker.chooserUnavailableCode,
        );
      });

      await expectLater(
        picker().pickFolder(),
        throwsA(isA<FolderPickerUnavailableException>()),
      );
    });

    test('treats any other platform error as no selection', () async {
      // A pick already in flight, or a selection with no local path. There is
      // nothing to fall back to and nothing to scan, so the caller sees the
      // same "nothing chosen" it sees for a cancel.
      handleWith((_) async {
        throw PlatformException(code: 'pick_in_progress');
      });

      expect(await picker().pickFolder(), isNull);
    });
  });
}
