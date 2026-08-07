import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

@immutable
class InstallHistory {
  const InstallHistory({
    required this.firstInstallTime,
    required this.lastUpdateTime,
  });

  final int firstInstallTime;
  final int lastUpdateTime;

  /// Android preserves firstInstallTime across app updates while lastUpdateTime
  /// advances. A small tolerance avoids treating filesystem timestamp jitter on
  /// a fresh install as an update.
  bool get isUpdate => lastUpdateTime - firstInstallTime > 2000;
}

const MethodChannel _channel =
    MethodChannel('io.github.thezupzup.linthra/install_history');

Future<InstallHistory?> readPlatformInstallHistory() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
  try {
    final Map<Object?, Object?>? raw =
        await _channel.invokeMapMethod<Object?, Object?>('getInstallHistory');
    final Object? first = raw?['firstInstallTime'];
    final Object? last = raw?['lastUpdateTime'];
    if (first is! num || last is! num) return null;
    return InstallHistory(
      firstInstallTime: first.toInt(),
      lastUpdateTime: last.toInt(),
    );
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}
