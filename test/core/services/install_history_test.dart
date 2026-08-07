import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/services/install_history.dart';

void main() {
  test('fresh install is not classified as an update', () {
    const InstallHistory history = InstallHistory(
      firstInstallTime: 100000,
      lastUpdateTime: 100000,
    );

    expect(history.isUpdate, isFalse);
  });

  test('later package update is classified as an update', () {
    const InstallHistory history = InstallHistory(
      firstInstallTime: 100000,
      lastUpdateTime: 200000,
    );

    expect(history.isUpdate, isTrue);
  });
}
