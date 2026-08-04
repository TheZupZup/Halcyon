import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/music_folder.dart';
import 'package:linthra/core/services/folder_browsable_music_source.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/features/library/folder_browser_providers.dart';
import 'package:linthra/features/library/library_screen.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_sync_controller.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_sync_state.dart';
import 'package:linthra/features/settings/plex/plex_sync_controller.dart';
import 'package:linthra/features/settings/plex/plex_sync_state.dart';
import 'package:linthra/features/settings/subsonic/subsonic_sync_controller.dart';
import 'package:linthra/features/settings/subsonic/subsonic_sync_state.dart';

import 'fake_music_library_repository.dart';

/// Each provider's sync controller pinned to a fixed state, so a test can put
/// the Library in the exact "first sync in flight" moment.
class _FixedJellyfinSync extends JellyfinSyncController {
  _FixedJellyfinSync(this._fixed);
  final JellyfinSyncState _fixed;
  @override
  JellyfinSyncState build() => _fixed;
}

class _FixedSubsonicSync extends SubsonicSyncController {
  _FixedSubsonicSync(this._fixed);
  final SubsonicSyncState _fixed;
  @override
  SubsonicSyncState build() => _fixed;
}

class _FixedPlexSync extends PlexSyncController {
  _FixedPlexSync(this._fixed);
  final PlexSyncState _fixed;
  @override
  PlexSyncState build() => _fixed;
}

/// A folder-browsable source that never gets asked for anything: the Library
/// only needs it to be *present* for the browse tabs to appear, which is what
/// puts a syncing Navidrome/Subsonic on the tab path rather than the
/// folder-pick path.
class _StubFolderSource implements FolderBrowsableMusicSource {
  @override
  String get id => 'subsonic';

  @override
  String get displayName => 'Navidrome / Subsonic';

  @override
  Future<List<MusicFolder>> fetchRootFolders() async => const <MusicFolder>[];

  @override
  Future<MusicFolderListing> fetchFolder(String folderId) async =>
      MusicFolderListing.empty;
}

Future<void> _pumpLibrary(
  WidgetTester tester, {
  JellyfinSyncState jellyfin = const JellyfinSyncState(),
  SubsonicSyncState subsonic = const SubsonicSyncState(),
  PlexSyncState plex = const PlexSyncState(),
  bool hasFolderSources = false,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        // An empty catalog — the case onboarding starts from.
        musicLibraryRepositoryProvider
            .overrideWithValue(FakeMusicLibraryRepository()),
        jellyfinSyncControllerProvider
            .overrideWith(() => _FixedJellyfinSync(jellyfin)),
        subsonicSyncControllerProvider
            .overrideWith(() => _FixedSubsonicSync(subsonic)),
        plexSyncControllerProvider.overrideWith(() => _FixedPlexSync(plex)),
        folderBrowsableSourcesProvider.overrideWithValue(
          hasFolderSources
              ? <FolderBrowsableMusicSource>[_StubFolderSource()]
              : const <FolderBrowsableMusicSource>[],
        ),
      ],
      child: const MaterialApp(home: LibraryScreen()),
    ),
  );
  // Let the (empty) catalog load resolve. Don't pumpAndSettle: a syncing state
  // shows an endless progress spinner.
  await tester.pump();
  await tester.pump();
}

void main() {
  group('Library first-sync state is provider-aware', () {
    testWidgets('Plex: a scanning library never asks for a local folder',
        (tester) async {
      // The regression this whole change exists for. Plex exposes no folder
      // hierarchy, so before the fix an empty catalog + a scanning Plex library
      // fell straight through to "No music folder selected".
      await _pumpLibrary(tester, plex: const PlexSyncState.scanning());

      expect(find.text('Your Plex library is syncing'), findsOneWidget);
      expect(find.text('No music folder selected'), findsNothing);
      expect(find.text('Select a folder'), findsNothing);
    });

    testWidgets('Plex: the write phase counts as syncing too', (tester) async {
      // Plex writes in batches, so `syncing` (saving) is just as much part of
      // the first-run window as `scanning` (reading).
      await _pumpLibrary(
        tester,
        plex: const PlexSyncState.syncing(trackCount: 400),
      );

      expect(find.text('Your Plex library is syncing'), findsOneWidget);
      expect(find.text('No music folder selected'), findsNothing);
    });

    testWidgets('Jellyfin: names the source', (tester) async {
      await _pumpLibrary(tester, jellyfin: const JellyfinSyncState.syncing());

      expect(find.text('Your Jellyfin library is syncing'), findsOneWidget);
      expect(find.text('No music folder selected'), findsNothing);
    });

    testWidgets(
        'Subsonic: the catalog tabs read as filling, not empty, while syncing',
        (tester) async {
      // A connected Navidrome/Subsonic is folder-browsable, so the tabs show
      // immediately and the first sync lands on the Songs tab rather than the
      // folder-pick prompt. It must not claim the catalog is empty.
      await _pumpLibrary(
        tester,
        subsonic: const SubsonicSyncState.syncing(),
        hasFolderSources: true,
      );

      // findsWidgets, not findsOneWidget: TabBarView may keep a neighbouring
      // catalog tab alive, and every catalog tab shows the same headline.
      expect(
        find.text('Your Navidrome / Subsonic library is syncing'),
        findsWidgets,
      );
      expect(find.text('No songs in the synced catalog'), findsNothing);
      expect(find.text('No music folder selected'), findsNothing);
      // Folder browsing is genuinely available ahead of the sync, so the tabs
      // and the pointer to Folders both stay.
      expect(find.byKey(const Key('library_tabs')), findsOneWidget);
      expect(find.textContaining('Folders'), findsWidgets);
    });

    testWidgets('several sources syncing at once stay general', (tester) async {
      await _pumpLibrary(
        tester,
        jellyfin: const JellyfinSyncState.syncing(),
        plex: const PlexSyncState.scanning(),
      );

      // Naming one server would be wrong and listing both is noise.
      expect(find.text('Your libraries are syncing'), findsOneWidget);
      expect(find.text('Your Jellyfin library is syncing'), findsNothing);
      expect(find.text('No music folder selected'), findsNothing);
    });

    testWidgets('local-only: nothing syncing still prompts for a folder',
        (tester) async {
      await _pumpLibrary(tester);

      // The pre-existing behaviour, unchanged: no server sync in flight and an
      // empty catalog is a genuine "pick a folder" moment.
      expect(find.text('No music folder selected'), findsOneWidget);
      expect(find.text('Select a folder'), findsOneWidget);
      expect(find.textContaining('is syncing'), findsNothing);
      expect(find.text('Your libraries are syncing'), findsNothing);
    });

    testWidgets('a finished sync falls back to the normal empty state',
        (tester) async {
      // Success/error/idle are all "not syncing" — the screen must go back to
      // its ordinary empty state rather than pinning a spinner.
      await _pumpLibrary(
        tester,
        jellyfin: const JellyfinSyncState.error('Something went wrong.'),
        plex: const PlexSyncState.done(trackCount: 0, message: 'Nothing here.'),
      );

      expect(find.text('No music folder selected'), findsOneWidget);
      expect(find.textContaining('is syncing'), findsNothing);
    });
  });
}
