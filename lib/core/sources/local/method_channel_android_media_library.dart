import 'dart:io';

import 'package:flutter/services.dart';

import 'android_media_library.dart';
import 'folder_scan_exception.dart';
import 'method_channel_saf_document_lister.dart';
import 'saf_document_lister.dart';

/// Native Android implementation of [AndroidMediaLibrary].
///
/// The platform side owns runtime-permission prompting and the MediaStore query;
/// Dart receives only a small typed status plus the same secret-free document
/// shape used by the SAF scanner.
class MethodChannelAndroidMediaLibrary implements AndroidMediaLibrary {
  const MethodChannelAndroidMediaLibrary();

  static const String _channelName =
      'io.github.thezupzup.linthra/media_library';
  static const MethodChannel _channel = MethodChannel(_channelName);

  @override
  Future<AndroidMusicPermissionStatus> permissionStatus() async {
    if (!Platform.isAndroid) {
      return AndroidMusicPermissionStatus.unavailable;
    }
    try {
      final String? raw =
          await _channel.invokeMethod<String>('permissionStatus');
      return parsePermissionStatus(raw);
    } on MissingPluginException {
      return AndroidMusicPermissionStatus.unavailable;
    } on PlatformException {
      return AndroidMusicPermissionStatus.unavailable;
    }
  }

  @override
  Future<AndroidMusicPermissionStatus> requestPermission() async {
    if (!Platform.isAndroid) {
      return AndroidMusicPermissionStatus.unavailable;
    }
    try {
      final String? raw =
          await _channel.invokeMethod<String>('requestPermission');
      return parsePermissionStatus(raw);
    } on MissingPluginException {
      return AndroidMusicPermissionStatus.unavailable;
    } on PlatformException {
      return AndroidMusicPermissionStatus.denied;
    }
  }

  @override
  Future<void> openAppSettings() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('openAppSettings');
    } on MissingPluginException {
      // Older builds simply omit the shortcut; no permission is broadened.
    } on PlatformException {
      // The settings shortcut is convenience only; failure is non-fatal.
    }
  }

  @override
  Future<SafScanResult> listDeviceAudio() async {
    if (!Platform.isAndroid) {
      throw const SafUnsupportedException();
    }
    final Map<Object?, Object?>? result;
    try {
      result = await _channel.invokeMapMethod<Object?, Object?>(
        'listDeviceAudio',
      );
    } on MissingPluginException {
      throw const SafUnsupportedException();
    } on PlatformException catch (error) {
      if (error.code == 'permission_denied') {
        throw const FolderScanException(
          'Music and audio access is turned off. Enable it in Android settings '
          'or choose a folder instead.',
          code: 'permission_denied',
        );
      }
      throw FolderScanException(
        "Couldn't read Android's shared music library. Try again, or choose a "
        'folder instead.',
        code: error.code,
      );
    }
    return MethodChannelSafDocumentLister.parseScanResult(result);
  }

  /// Pure parser so status handling is testable without a device/channel.
  static AndroidMusicPermissionStatus parsePermissionStatus(String? raw) {
    switch (raw) {
      case 'allowed':
        return AndroidMusicPermissionStatus.allowed;
      case 'denied':
        return AndroidMusicPermissionStatus.denied;
      case 'notRequested':
        return AndroidMusicPermissionStatus.notRequested;
      default:
        return AndroidMusicPermissionStatus.unavailable;
    }
  }
}
