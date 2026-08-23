import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/lifecycle/async_disposal_registry.dart';
import '../core/models/plex_session.dart';
import '../core/models/subsonic_session.dart';
import '../core/services/artwork_disk_cache.dart';
import '../core/services/media_session_binding.dart';
import '../core/services/playback_session_persistence.dart';
import '../core/sources/plex/plex_artwork.dart';
import '../core/sources/subsonic/subsonic_artwork.dart';
import '../data/repositories/download_repository_provider.dart';
import '../data/repositories/favorites_repository_provider.dart';
import '../data/repositories/music_library_repository_provider.dart';
import '../data/repositories/playback_session_store_provider.dart';
import '../data/repositories/playlist_repository_provider.dart';
import '../data/repositories/remote_cache_index_provider.dart';
import '../features/player/media_artwork_providers.dart';
import '../features/player/player_providers.dart';
import '../features/settings/jellyfin/jellyfin_settings_controller.dart';
import '../features/settings/playback/normalize_volume_controller.dart';
import '../features/settings/plex/plex_settings_controller.dart';
import '../features/settings/subsonic/subsonic_settings_controller.dart';
import '../shared/widgets/artwork_image.dart';

export 'application_container.dart' show productionApplicationOverrides;

/// Owns the root [ProviderContainer] and every resource `main()` installs
/// outside Riverpod.
///
/// [shutdown] is idempotent, safe after a partial startup, and — the part that
/// makes it a lifecycle rather than a best-effort teardown — **awaited to
/// completion**: when its future completes, every app-owned resource that has
/// to be gone before the app can start again (the SQLite connection, the audio
/// engine, the Jellyfin control socket, the artwork HTTP client, the
/// subscriptions and global hooks installed at bootstrap) has actually
/// finished closing. See [AsyncDisposalRegistry] for how the asynchronous half
/// of that guarantee is collected out of Riverpod's synchronous
/// `ProviderContainer.dispose()`.
///
/// One thing it deliberately does not release: the Android media session. The
/// graceful-shutdown path is desktop-only (see `PlatformShutdownPolicy`), where
/// the media-session binding is the inert one; on Android the session belongs
/// to `audio_service`'s foreground service and the platform, not to this
/// handle.
class ApplicationHandle {
  /// Creates a handle for [container].
  ///
  /// [bootstrapApplication] registers what it owns as it goes; the two named
  /// resources are accepted here so a caller that wired the same two things
  /// itself (tests, and any future embedder) gets the same teardown.
  ApplicationHandle({
    required this.container,
    ProviderSubscription<AsyncValue<bool>>? normalizeVolumeSubscription,
    ArtworkDiskCache? artworkDiskCache,
  }) : _asyncDisposals = container.read(asyncDisposalRegistryProvider) {
    if (normalizeVolumeSubscription != null) {
      ownSubscription(normalizeVolumeSubscription);
    }
    if (artworkDiskCache != null) {
      ownArtworkDiskCache(artworkDiskCache);
    }
  }

  final ProviderContainer container;

  /// The container's collector of asynchronous provider teardown. Captured at
  /// construction because it cannot be read back once the container is gone.
  final AsyncDisposalRegistry _asyncDisposals;

  /// Teardown steps for everything installed *outside* Riverpod, newest first:
  /// bootstrap registers each one the moment the matching resource exists, so a
  /// bootstrap that throws halfway still unwinds exactly what it created.
  final List<FutureOr<void> Function()> _teardowns =
      <FutureOr<void> Function()>[];

  Future<void>? _shutdown;

  /// Whether [shutdown] has been started.
  bool get isShuttingDown => _shutdown != null;

  /// Registers [teardown] to run during [shutdown], before the container is
  /// disposed. Steps run in reverse registration order, and a step that throws
  /// never stops the ones behind it.
  void own(FutureOr<void> Function() teardown) => _teardowns.add(teardown);

  /// Closes [subscription] on shutdown.
  void ownSubscription(ProviderSubscription<Object?> subscription) =>
      own(subscription.close);

  /// Disposes [cache] and clears the global artwork-cache hook on shutdown.
  void ownArtworkDiskCache(ArtworkDiskCache cache) {
    own(() {
      installArtworkDiskCache(null);
      cache.dispose();
    });
  }

  /// Waits for best-effort startup work before [shutdown] completes.
  ///
  /// Bootstrap deliberately starts a couple of things without awaiting them so
  /// the first frame is not held up. "Not awaited by startup" must not mean
  /// "still running while the next container opens the same files", so the work
  /// is parked in the same registry the asynchronous teardown uses.
  void ownPendingWork(Future<void> work) => _asyncDisposals.track(work);

  /// Clears the global artwork-resolver hook on shutdown.
  void ownArtworkReferenceResolver() {
    own(() => installArtworkReferenceResolver(null));
  }

  /// Stops playback, releases everything installed at bootstrap, disposes the
  /// root container, and waits for the asynchronous teardown that container
  /// started to finish.
  ///
  /// Never throws: a resource that fails to close is skipped so the ones behind
  /// it still get their chance (the failures stay readable through
  /// [AsyncDisposalRegistry.failures]). Calling it again — or concurrently —
  /// returns the same future instead of tearing anything down twice.
  Future<void> shutdown() => _shutdown ??= _runShutdown();

  Future<void> _runShutdown() async {
    // Silence the speakers first, before anything it depends on goes away.
    await _guard(() async {
      if (!container.exists(playbackControllerProvider)) return;
      await container.read(playbackControllerProvider).stop();
    });

    // The engines are also disposed by their providers below; doing it here
    // first keeps the audio device release ahead of the rest of the teardown,
    // and both disposals are idempotent.
    await _guard(() async {
      if (!container.exists(playbackControllerProvider)) return;
      await container.read(playbackControllerProvider).dispose();
    });
    await _guard(() async {
      if (!container.exists(localPlaybackControllerProvider)) return;
      await container.read(localPlaybackControllerProvider).dispose();
    });

    // Snapshot first: a teardown is allowed to register another one (and must
    // not trip a concurrent modification if it does).
    final List<FutureOr<void> Function()> steps =
        List<FutureOr<void> Function()>.of(_teardowns.reversed);
    _teardowns.clear();
    for (final FutureOr<void> Function() teardown in steps) {
      await _guard(teardown);
    }

    await _guard(container.dispose);

    // `ProviderContainer.dispose()` only *starts* asynchronous teardown; this
    // is where "the database is closed" becomes true rather than pending.
    await _asyncDisposals.settle();
  }

  Future<void> _guard(FutureOr<void> Function() step) async {
    try {
      await step();
    } catch (_) {
      // Best-effort: shutdown must never throw.
    }
  }
}

/// Wires the same side-effect services and session warm-up `main()` performs
/// between container creation and `runApp`.
///
/// Exception-safe: if any step throws, everything already initialized is torn
/// down (through the very same [ApplicationHandle.shutdown] the app uses) and
/// the original error is rethrown with its original stack trace. `main()` never
/// receives a handle for a failed bootstrap, so the cleanup cannot be left to
/// a caller that has nothing to call it on.
Future<ApplicationHandle> bootstrapApplication(
  ProviderContainer container, {
  bool installPersistentArtworkCache = true,
  Directory? artworkCacheDirectory,
}) async {
  final ApplicationHandle handle = ApplicationHandle(container: container);
  try {
    // Attaching the session is best-effort and platform-routed: on a platform
    // with no media session (Linux today) the binding is the inert one and
    // `audio_service` is never initialised at all. On Android it attaches the
    // real session; the handler mirrors the controller and outlives this scope
    // with the container.
    await const PlatformMediaSessionBinding().attach(
      container.read(playbackControllerProvider),
      container.read(musicLibraryRepositoryProvider),
      playlists: container.read(playlistRepositoryProvider),
      favorites: container.read(favoritesRepositoryProvider),
      downloads: container.read(downloadRepositoryProvider),
      artwork: container.read(mediaArtworkCacheProvider),
    );

    // Side-effect-only services: instantiating each one wires its listener.
    // They are disposed with the container, and — because each registers with
    // [AsyncDisposalRef.onDisposeAsync] — awaited by [ApplicationHandle].
    container.read(mediaArtworkPrewarmServiceProvider);
    container.read(smartPrecacheServiceProvider);
    container.read(remotePrebufferServiceProvider);
    // Loads and prunes the credential-free remote-cache manifest off the
    // first-frame path. Owned rather than merely unawaited: it writes to the
    // app-support directory, so a restart must not race a prune still in
    // flight.
    handle.ownPendingWork(container.read(remoteCacheIndexProvider).load());
    container.read(playbackReportingServiceProvider);
    container.read(remoteControlServiceProvider);
    container.read(remoteControlActivatorProvider);

    // Mirror the user's "Normalize volume" choice onto the local audio engine,
    // seeding the persisted value now and pushing every later toggle.
    handle.ownSubscription(
      container.listen<AsyncValue<bool>>(
        normalizeVolumeControllerProvider,
        (_, next) {
          container
              .read(localPlaybackControllerProvider)
              .setVolumeNormalizationEnabled(next.valueOrNull ?? false);
        },
        fireImmediately: true,
      ),
    );

    // Warm the persisted sessions before the first frame so a synced remote
    // track can stream on the first tap. Best-effort and secret-free: a
    // missing/corrupt record loads as "not connected".
    for (final Future<void> Function() ensureLoaded
        in <Future<void> Function()>[
      container.read(jellyfinSettingsControllerProvider.notifier).ensureLoaded,
      container.read(subsonicSettingsControllerProvider.notifier).ensureLoaded,
      container.read(plexSettingsControllerProvider.notifier).ensureLoaded,
    ]) {
      try {
        await ensureLoaded();
      } catch (_) {
        // Ignore: the user can still connect in Settings.
      }
    }

    // Teach the shared artwork seam how to turn a credential-free cover
    // reference (subsonic-cover:<id> or plex-thumb:<path>) into an
    // authenticated cover URL, weaving the live session's credential in at
    // render time. Secret-free: only the resolved URL is built, never logged.
    Uri? resolveArtworkReference(Uri reference) {
      final SubsonicSession? subsonicSession =
          container.read(subsonicSettingsControllerProvider.notifier).session;
      if (subsonicSession != null) {
        final Uri? resolved =
            SubsonicArtwork.resolve(reference, subsonicSession);
        if (resolved != null) return resolved;
      }
      final PlexSession? plexSession =
          container.read(plexMusicSourceProvider)?.session;
      if (plexSession != null) {
        final Uri? resolved = PlexArtwork.resolve(reference, plexSession);
        if (resolved != null) return resolved;
      }
      return null;
    }

    // Global hooks: owned from the moment they are installed, so a later
    // bootstrap failure cannot leave this container's closures wired into the
    // process-wide artwork seam.
    installArtworkReferenceResolver(resolveArtworkReference);
    handle.ownArtworkReferenceResolver();

    if (installPersistentArtworkCache) {
      // Persistent, credential-free artwork cache (issue #356). Only the
      // credential-free key ever reaches disk — see [ArtworkDiskCache].
      final ArtworkDiskCache artworkDiskCache = ArtworkDiskCache(
        directory:
            artworkCacheDirectory ?? await ArtworkDiskCache.defaultDirectory(),
        resolveFetchUrl: (Uri key) => resolveArtworkReference(key) ?? key,
      );
      installArtworkDiskCache(artworkDiskCache);
      handle.ownArtworkDiskCache(artworkDiskCache);
    }

    // Pull the user's server favourites and playlists so both reflect the
    // servers from the first frame. Best-effort and offline-tolerant.
    //
    // Not owned like the manifest load above: these are network round-trips,
    // and making shutdown wait for one would hand a shutting-down app's exit
    // time to a slow or unreachable server. They write only through
    // repositories that are themselves torn down by the container, and both
    // swallow their own failures, so an in-flight refresh at shutdown ends
    // without touching anything the next container owns.
    unawaited(container.read(favoritesRepositoryProvider).refreshFromRemote());
    unawaited(container.read(playlistRepositoryProvider).refreshFromRemote());

    // Linux crash-safe restore: rehydrate any persisted logical queue as a
    // paused/resumable state. Never autoplay, and never block launch on a bad
    // record.
    final PlaybackSessionPersistence? sessionPersistence =
        container.read(playbackSessionPersistenceProvider);
    if (sessionPersistence != null) {
      try {
        await sessionPersistence.restore();
      } catch (_) {
        // Ignore: a failed restore must never stop the app from launching.
      }
    }

    return handle;
  } catch (error, stackTrace) {
    // Unwind everything this bootstrap managed to create, then surface the
    // original failure untouched — the cleanup must not become the error the
    // caller sees.
    await handle.shutdown();
    Error.throwWithStackTrace(error, stackTrace);
  }
}
