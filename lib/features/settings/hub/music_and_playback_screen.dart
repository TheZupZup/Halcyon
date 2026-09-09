import 'package:flutter/material.dart';

import '../../../app/dimens.dart';
import '../playback/audio_output_settings_section.dart';
import '../playback/playback_settings_section.dart';
import '../source/default_provider_section.dart';
import '../source/playback_source_strategy_section.dart';
import 'settings_detail_scaffold.dart';

/// The "Music & playback" page of the Settings hub.
///
/// Groups the choices about *which* copy of a song plays and *how* it sounds:
/// the default source, the playback source strategy, volume normalization, and
/// — where the platform lets Linthra route audio itself — which output device
/// plays. Each card is the existing section, unchanged: nothing here touches
/// the playback engine or provider logic.
class MusicAndPlaybackScreen extends StatelessWidget {
  const MusicAndPlaybackScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const SettingsDetailScaffold(
      title: 'Music & playback',
      children: <Widget>[
        DefaultProviderSettingsSection(),
        SizedBox(height: AppSpacing.md),
        PlaybackSourceStrategySettingsSection(),
        SizedBox(height: AppSpacing.md),
        PlaybackSettingsSection(),
        // Renders nothing where output routing belongs to the system (Android).
        SizedBox(height: AppSpacing.md),
        AudioOutputSettingsSection(),
      ],
    );
  }
}
