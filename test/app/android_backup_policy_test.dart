import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const List<String> _buildTypes = <String>[
  'debug',
  'profile',
  'release',
];

const List<String> _backupDomains = <String>[
  'root',
  'file',
  'database',
  'sharedpref',
  'external',
  'device_root',
  'device_file',
  'device_database',
  'device_sharedpref',
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

    test('legacy backup excludes every private storage domain', () {
      final String rules = File(
        'android/app/src/main/res/xml/backup_rules.xml',
      ).readAsStringSync();

      for (final String domain in _backupDomains) {
        expect(
          rules,
          contains('<exclude domain="$domain" path="." />'),
          reason: 'Legacy backup must exclude the $domain domain.',
        );
      }
    });

    test('Android 12+ excludes all data from cloud and device transfer', () {
      final String rules = File(
        'android/app/src/main/res/xml/data_extraction_rules.xml',
      ).readAsStringSync();
      final String cloudBackup = _xmlSection(rules, 'cloud-backup');
      final String deviceTransfer = _xmlSection(rules, 'device-transfer');

      for (final String domain in _backupDomains) {
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
    });
  });
}
