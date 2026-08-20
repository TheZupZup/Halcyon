import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';
import 'package:linthra/data/repositories/playback_session_store_provider.dart';
import 'package:linthra/features/player/player_providers.dart';

import '../../support/fake_audio_player.dart';

void main() {
  test('playback session persistence is Linux-only', () {
    final ProviderContainer linux = ProviderContainer(
      overrides: <Override>[
        hostPlatformProvider.overrideWithValue(HostPlatform.linux),
        linuxAudioPlayerProvider.overrideWithValue(FakeAudioPlayer()),
      ],
    );
    addTearDown(linux.dispose);
    expect(linux.read(playbackSessionPersistenceProvider), isNotNull);

    final ProviderContainer android = ProviderContainer(
      overrides: <Override>[
        hostPlatformProvider.overrideWithValue(HostPlatform.android),
      ],
    );
    addTearDown(android.dispose);
    expect(android.read(playbackSessionPersistenceProvider), isNull);
  });
}
