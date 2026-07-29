import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/repositories/download_preferences.dart';
import 'package:linthra/data/repositories/in_memory_download_preferences.dart';
import 'package:linthra/data/repositories/shared_preferences_download_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('mobile data profile preference', () {
    test('in-memory defaults to Wi-Fi only', () async {
      final prefs = InMemoryDownloadPreferences();

      expect(await prefs.mobileDataProfile(), MobileDataProfile.wifiOnly);
      expect(await prefs.allowMobileData(), isFalse);
    });

    test('in-memory distinguishes save-data and unlimited', () async {
      final prefs = InMemoryDownloadPreferences();

      await prefs.setMobileDataProfile(MobileDataProfile.saveData);
      expect(await prefs.mobileDataProfile(), MobileDataProfile.saveData);
      expect(await prefs.allowMobileData(), isTrue);

      await prefs.setMobileDataProfile(MobileDataProfile.unlimited);
      expect(await prefs.mobileDataProfile(), MobileDataProfile.unlimited);
      expect(await prefs.allowMobileData(), isTrue);
    });

    group('shared_preferences', () {
      setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

      test('defaults to Wi-Fi only when no choice exists', () async {
        const prefs = SharedPreferencesDownloadPreferences();

        expect(await prefs.mobileDataProfile(), MobileDataProfile.wifiOnly);
      });

      test('persists every profile across instances', () async {
        const prefs = SharedPreferencesDownloadPreferences();

        for (final MobileDataProfile profile in MobileDataProfile.values) {
          await prefs.setMobileDataProfile(profile);
          const reopened = SharedPreferencesDownloadPreferences();
          expect(await reopened.mobileDataProfile(), profile);
        }
      });

      test('migrates the old false boolean to Wi-Fi only', () async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          'downloads_allow_mobile_data': false,
        });
        const prefs = SharedPreferencesDownloadPreferences();

        expect(await prefs.mobileDataProfile(), MobileDataProfile.wifiOnly);
      });

      test('migrates the old true boolean to unlimited', () async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          'downloads_allow_mobile_data': true,
        });
        const prefs = SharedPreferencesDownloadPreferences();

        expect(await prefs.mobileDataProfile(), MobileDataProfile.unlimited);
      });

      test('legacy setter stays compatible with existing call sites', () async {
        const prefs = SharedPreferencesDownloadPreferences();

        await prefs.setAllowMobileData(true);
        expect(await prefs.mobileDataProfile(), MobileDataProfile.unlimited);

        await prefs.setAllowMobileData(false);
        expect(await prefs.mobileDataProfile(), MobileDataProfile.wifiOnly);
      });
    });
  });
}
