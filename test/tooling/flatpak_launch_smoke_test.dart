import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String smoke;

  setUpAll(() {
    smoke = File('scripts/flatpak_launch_smoke.sh').readAsStringSync();
  });

  test('launch smoke installs only from the local CI repository', () {
    expect(smoke, contains(r'REMOTE_NAME="linthra-ci-smoke-$$"'));
    expect(smoke, contains('--no-gpg-verify'));
    expect(smoke, contains('flatpak --user install -y'));
    expect(smoke, isNot(contains('https://')));
  });

  test('launch smoke preserves pre-existing Linthra installations', () {
    expect(smoke, contains(r'flatpak --user info "$APP_ID"'));
    expect(smoke, contains(r'flatpak --system info "$APP_ID"'));
    expect(smoke, contains(r'$APP_ID is already installed'));
  });

  test('launch smoke starts the packaged app and waits for a real window', () {
    expect(smoke, contains(r'flatpak run "$APP_ID"'));
    expect(smoke, contains('xwininfo -root -tree'));
    expect(smoke, contains('WINDOW_TITLE="Linthra"'));
    expect(smoke, contains('xvfb-run --auto-servernum'));
    expect(smoke, contains('dbus-run-session'));
  });

  // #554. A window is not enough: it has to be a window the desktop recognises
  // as Linthra. Under Xvfb the sandbox takes its --socket=fallback-x11 path, so
  // both of these are readable as X properties on the packaged app.
  test('launch smoke holds the packaged window to the application id', () {
    expect(smoke, contains('xprop is not installed'));
    expect(smoke, contains(r'xprop -id "$window_id" WM_CLASS'));
    expect(
      smoke,
      contains(r'expected="WM_CLASS(STRING) = \"$APP_ID\", \"$APP_ID\""'),
    );
  });

  test('launch smoke requires the packaged window to carry its icon', () {
    expect(smoke, contains(r'xprop -id "$window_id" _NET_WM_ICON'));
    expect(smoke, contains('carries no _NET_WM_ICON'));
  });

  test('launch smoke re-checks identity after a close and reopen', () {
    expect(smoke, contains('launch_and_check "first launch"'));
    expect(smoke, contains('launch_and_check "reopen after close"'));
  });

  test('launch smoke cleans up app and temporary remote', () {
    expect(smoke, contains(r'flatpak kill "$APP_ID"'));
    expect(smoke, contains(r'flatpak --user uninstall -y "$APP_ID"'));
    expect(smoke, contains(r'flatpak --user remote-delete "$REMOTE_NAME"'));
    expect(smoke, contains('trap cleanup EXIT'));
  });

  test('launch smoke has no external download command', () {
    expect(smoke, isNot(contains('curl ')));
    expect(smoke, isNot(contains('wget ')));
  });
}
