import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/lifecycle/async_disposal_registry.dart';
import '../../../core/models/cast_state.dart';
import '../../../core/services/cast/cast_containment.dart';
import '../../../core/services/cast/cast_media_resolver.dart';
import '../../../core/services/cast/cast_service.dart';
import '../../../core/services/cast/routing_cast_media_resolver.dart';
import '../../../core/services/cast/unavailable_cast_service.dart';
import '../../../core/sources/jellyfin/jellyfin_cast_media_resolver.dart';
import '../../../core/sources/subsonic/subsonic_cast_media_resolver.dart';
import '../../settings/jellyfin/jellyfin_settings_controller.dart';
import '../../settings/subsonic/subsonic_settings_controller.dart';

/// The single [CastService] the app drives casting through.
///
/// Defaults to [UnavailableCastService] so tests (and any platform without a
/// cast backend) keep an honest, inert cast button. A service test that needs
/// live behaviour overrides this provider with its own fake; production applies
/// [containedCastServiceOverride].
final castServiceProvider = Provider<CastService>((ref) {
  final service = UnavailableCastService();
  ref.onDisposeAsync(service.dispose);
  return service;
});

/// Streams [CastState] for the UI. Until the first event arrives, callers fall
/// back to the service's synchronous [CastService.state].
final castStateProvider = StreamProvider<CastState>((ref) {
  return ref.watch(castServiceProvider).stateStream;
});

/// Resolves the current track into a castable URL on demand at cast time.
/// Jellyfin and Subsonic tracks each mint an authenticated stream URL (the
/// receiver fetches it directly); on-device files report
/// [CastMediaResolver.canCast] false so the service can show a clear limitation
/// instead of failing. Composed so multiple remote sources cast through one
/// resolver.
///
/// Unused by production while [CastContainment.isActive] — nothing resolves a
/// stream URL for a receiver when no session can be opened. It stays wired and
/// tested because [#576](https://github.com/TheZupZup/Linthra/issues/576) builds
/// on it, rather than rebuilding it afterwards.
final castMediaResolverProvider = Provider<CastMediaResolver>((ref) {
  return RoutingCastMediaResolver(<CastMediaResolver>[
    JellyfinCastMediaResolver(() => ref.read(jellyfinMusicSourceProvider)),
    SubsonicCastMediaResolver(() => ref.read(subsonicMusicSourceProvider)),
  ]);
});

/// Production binding: the security containment ([CastContainment]).
///
/// Every platform gets [UnavailableCastService], so shipped builds construct no
/// cast transport and open no receiver socket. This *is* the production path:
/// there is no branch here that builds a live backend, and no flag that selects
/// one, because a second production path is exactly what containment cannot
/// have. The cast button and device sheet are unchanged; they read the message
/// and say casting is temporarily off.
///
/// Restoring casting is a separate reviewed change, tracked in
/// [#575](https://github.com/TheZupZup/Linthra/issues/575). Until then the
/// transport and the media handoff refuse independently of this provider, so
/// reverting this alone still cannot reach a receiver.
final containedCastServiceOverride = castServiceProvider.overrideWith((ref) {
  final service = UnavailableCastService(
    message: CastContainment.isActive ? CastContainment.userMessage : null,
  );
  ref.onDisposeAsync(service.dispose);
  return service;
});
