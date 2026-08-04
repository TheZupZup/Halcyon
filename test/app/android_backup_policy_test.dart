import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const List<String> _buildTypes = <String>[
  'debug',
  'profile',
  'release',
];

// These are the storage domains accepted by the Android lint schema used by
// Linthra's pinned release toolchain. Device-protected storage domains are not
// used by Linthra and previously caused lintVitalRelease to reject the build.
const List<String> _supportedBackupDomains = <String>[
  'root',
  'file',
  'database',
  'sharedpref',
  'external',
];

String _xmlSection(String xml, String tag) {
  final int start = xml.indexOf('<$tag>');
  final int end = xml.indexOf('</$tag>');
  expect(start, greaterThanOrEqualTo(0), reason: 'Missing <$tag> section.');
  expect(end, greaterThan(start), reason: 'Missing </$tag> section.');
  return xml.substring(start, end);
}

void main() {
  group('Android backup and restore policy', () {
    test('every build type disables restore without affecting app updates', () {
      for (final String buildType in _buildTypes) {
        final String manifest = File(
          'android/app/src/$buildType/AndroidManifest.xml',
        ).readAsStringSync();

        expect(
          manifest,
          contains('android:allowBackup="false"'),
          reason: '$buildType must not restore stale app data after reinstall.',
        );
        expect(
          manifest,
          contains('android:fullBackupContent="@xml/backup_rules"'),
          reason: '$buildType must bind the Android 11-and-lower rules.',
        );
        expect(
          manifest,
          contains(
            'android:dataExtractionRules="@xml/data_extraction_rules"',
          ),
          reason: '$buildType must bind the Android 12+ rules.',
        );
      }
    });

    test('legacy backup excludes every supported private storage domain', () {
      final String rules = File(
        'android/app/src/main/res/xml/backup_rules.xml',
      ).readAsStringSync();

      for (final String domain in _supportedBackupDomains) {
        expect(
          rules,
          contains('<exclude domain="$domain" path="." />'),
          reason: 'Legacy backup must exclude the $domain domain.',
        );
      }
      expect(
        rules,
        isNot(contains('domain="device_')),
        reason: 'Device-protected domains break lintVitalRelease in the pinned toolchain.',
      );
    });

    test('Android 12+ excludes all supported data from cloud and transfer', () {
      final String rules = File(
        'android/app/src/main/res/xml/data_extraction_rules.xml',
      ).readAsStringSync();
      final String cloudBackup = _xmlSection(rules, 'cloud-backup');
      final String deviceTransfer = _xmlSection(rules, 'device-transfer');

      for (final String domain in _supportedBackupDomains) {
        final String exclusion = '<exclude domain="$domain" path="." />';
        expect(
          cloudBackup,
          contains(exclusion),
          reason: 'Cloud backup must exclude the $domain domain.',
        );
        expect(
          deviceTransfer,
          contains(exclusion),
          reason: 'Device transfer must exclude the $domain domain.',
        );
      }
      expect(
        rules,
        isNot(contains('domain="device_')),
        reason: 'Device-protected domains break lintVitalRelease in the pinned toolchain.',
      );
    });
  });
}
