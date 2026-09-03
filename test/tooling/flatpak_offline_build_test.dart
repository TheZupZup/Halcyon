import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Flatpak build inputs are complete for an offline build', () {
    final ProcessResult result = Process.runSync(
      'python3',
      <String>['scripts/check_flatpak_offline_sources.py'],
    );

    expect(
      result.exitCode,
      0,
      reason: '${result.stdout}\n${result.stderr}',
    );
  });
}
