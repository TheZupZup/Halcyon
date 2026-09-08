import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/cast_media.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/cast/cast_media_access.dart';
import 'package:linthra/core/services/cast/cast_media_resolver.dart';
import 'package:linthra/core/services/cast/routing_cast_media_resolver.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_cast_media_resolver.dart';
import 'package:linthra/core/sources/subsonic/subsonic_cast_media_resolver.dart';

/// What a cast handoff actually delegates, per source
/// ([#576](https://github.com/TheZupZup/Linthra/issues/576)).
///
/// The point of the model is honesty, so these tests mostly guard against a
/// pleasant lie: a source that claims to hand over a scoped capability when its
/// server issues nothing of the sort, or a default that treats an undeclared
/// source as harmless. Neither Jellyfin nor Subsonic supports a per-item
/// capability today, and the tests say so on purpose — when one of them gains
/// one, this file is where the change shows up.
void main() {
  const Track jellyfinTrack =
      Track(id: 'j1', title: 'Streamed', uri: 'jellyfin:j1');
  const Track subsonicTrack =
      Track(id: 's1', title: 'Streamed', uri: 'subsonic:s1');
  const Track localTrack =
      Track(id: 'l1', title: 'On device', uri: '/music/x.mp3');

  group('the model', () {
    test('an undeclared handoff is read as the widest one', () {
      // A source that says nothing must never be mistaken for a safe one.
      expect(CastMediaAccess.undeclared.delegatesAccountCredential, isTrue);
      expect(CastMediaAccess.undeclared.isLeastPrivilege, isFalse);
      expect(CastMediaAccess.undeclared.scope, CastMediaScope.account);
    });

    test('media that nobody described defaults to that reading', () {
      final CastMedia media = CastMedia(
        url: Uri.parse('https://music.example.test/stream?api_key=TOKEN'),
        contentType: 'audio/mpeg',
      );

      expect(media.access, CastMediaAccess.undeclared);
    });

    test('nothing is delegated when nothing is handed over', () {
      expect(CastMediaAccess.none.delegation, CastMediaDelegation.none);
      expect(CastMediaAccess.none.scope, CastMediaScope.nothing);
      expect(CastMediaAccess.none.isLeastPrivilege, isTrue);
      expect(CastMediaAccess.none.delegatesAccountCredential, isFalse);
    });

    test('a per-item capability is what least privilege means here', () {
      const CastMediaAccess signedUrl = CastMediaAccess(
        delegation: CastMediaDelegation.scopedCapability,
        scope: CastMediaScope.singleItem,
        summary: 'A signed URL for this item only.',
        lifetime: Duration(minutes: 15),
        revocableIndependently: true,
      );

      expect(signedUrl.isLeastPrivilege, isTrue);
      expect(signedUrl.delegatesAccountCredential, isFalse);
      expect(signedUrl.lifetime, const Duration(minutes: 15));
    });

    test('describing a handoff never quotes one', () {
      // The summary is written for docs and diagnostics, so it must stay the
      // kind of sentence that is safe to print anywhere.
      for (final CastMediaAccess access in <CastMediaAccess>[
        CastMediaAccess.undeclared,
        CastMediaAccess.none,
        JellyfinCastMediaResolver.access,
        SubsonicCastMediaResolver.access,
      ]) {
        expect(access.summary, isNotEmpty);
        expect(access.summary, isNot(contains('://')));
        expect(access.summary, isNot(contains('=')));
        expect(access.toString(), isNot(contains('://')));
      }
    });
  });

  group('what each server actually supports', () {
    test('Jellyfin delegates the session token, account-wide', () {
      // Jellyfin's stream endpoint authenticates with the session access token
      // in api_key. There is no per-item signed URL to ask for, so claiming a
      // narrower delegation would be inventing a restriction the server does
      // not enforce.
      const CastMediaAccess access = JellyfinCastMediaResolver.access;

      expect(access.delegation, CastMediaDelegation.accountCredential);
      expect(access.scope, CastMediaScope.account);
      expect(access.isLeastPrivilege, isFalse);
      expect(access.lifetime, isNull);
      expect(access.revocableIndependently, isFalse);
    });

    test('neither source claims that signing out takes the access back', () {
      // Signing out of Jellyfin here forgets the token locally; it does not ask
      // the server to invalidate it. Subsonic's credential is derived from the
      // password, so only changing that password invalidates a kept copy.
      // Saying "until you sign out" would be the comfortable answer and the
      // wrong one — this model exists to avoid exactly that.
      for (final CastMediaAccess access in <CastMediaAccess>[
        JellyfinCastMediaResolver.access,
        SubsonicCastMediaResolver.access,
      ]) {
        expect(access.lifetime, isNull);
        expect(access.summary.toLowerCase(), isNot(contains('sign out')));
        expect(access.summary.toLowerCase(), isNot(contains('session ends')));
      }
    });

    test('Subsonic delegates the salted credential, account-wide', () {
      const CastMediaAccess access = SubsonicCastMediaResolver.access;

      expect(access.delegation, CastMediaDelegation.accountCredential);
      expect(access.scope, CastMediaScope.account);
      expect(access.lifetime, isNull);
      expect(access.revocableIndependently, isFalse);
    });

    test('each resolver answers for its own tracks and nothing else', () {
      final JellyfinCastMediaResolver jellyfin =
          JellyfinCastMediaResolver(() => null);
      final SubsonicCastMediaResolver subsonic =
          SubsonicCastMediaResolver(() => null);

      expect(
          jellyfin.accessFor(jellyfinTrack), JellyfinCastMediaResolver.access);
      expect(jellyfin.accessFor(localTrack), CastMediaAccess.none);
      expect(
          subsonic.accessFor(subsonicTrack), SubsonicCastMediaResolver.access);
      expect(subsonic.accessFor(localTrack), CastMediaAccess.none);
    });
  });

  group('routing', () {
    final CastMediaResolver resolver = RoutingCastMediaResolver(
      <CastMediaResolver>[
        JellyfinCastMediaResolver(() => null),
        SubsonicCastMediaResolver(() => null),
      ],
    );

    test('reports the delegation of the source that would cast the track', () {
      expect(
        resolver.accessFor(jellyfinTrack),
        JellyfinCastMediaResolver.access,
      );
      expect(
        resolver.accessFor(subsonicTrack),
        SubsonicCastMediaResolver.access,
      );
    });

    test('a track nothing can cast delegates nothing', () {
      expect(resolver.accessFor(localTrack), CastMediaAccess.none);
    });

    test('asking costs nothing: no session, no network, no resolution', () {
      // Both resolvers are signed out (their source supplier returns null), so
      // resolving would throw. Describing the delegation must not.
      expect(() => resolver.accessFor(jellyfinTrack), returnsNormally);
      expect(
          resolver.resolve(jellyfinTrack), throwsA(isA<CastMediaException>()));
    });
  });
}
