# What a cast handoff delegates (least-privilege media access)

When Linthra casts, it stops fetching the audio and tells a device on the
network to fetch it instead. That device needs to be allowed to, so something is
delegated. This page is what each supported server actually lets us delegate,
what that costs, and what would have to change for a handoff to give a receiver
no more than the one song it is playing. It tracks
[#576](https://github.com/TheZupZup/Linthra/issues/576).

This is defence in depth, not the fix. Narrowing what a receiver gets does not
make an unauthenticated receiver safe to talk to — that is
[#575](https://github.com/TheZupZup/Linthra/issues/575) and
[cast-receiver-trust.md](cast-receiver-trust.md). Casting stays off in shipped
builds until that lands.

## The model in code

`CastMediaAccess` (`lib/core/services/cast/cast_media_access.dart`) is how a
source declares what casting one of its tracks hands over:

- **`delegation`** — a `scopedCapability` (a signed or otherwise scoped URL good
  for this item and nothing else), an `accountCredential` (the credential
  itself, because that is all the server accepts), or `none`.
- **`scope`** — how far it reaches if it is observed or kept: the single item, or
  the whole account.
- **`lifetime`** / **`revocableIndependently`** — whether the server bounds it,
  and whether the user can revoke this access without invalidating their session
  or changing their password.
- **`summary`** — a short sentence safe to print anywhere. It describes a URL's
  authority, never its contents.

Each resolver declares its own (`JellyfinCastMediaResolver.access`,
`SubsonicCastMediaResolver.access`), `CastMediaResolver.accessFor(track)` answers
without resolving or touching the network, and resolved `CastMedia` carries the
same answer. A source that declares nothing gets `CastMediaAccess.undeclared`,
which reads as account-level exposure: an omission shows up as an overstatement,
never as a quiet under-statement.

`test/core/services/cast/cast_media_access_test.dart` holds the model to that,
including the part that matters most — no source may claim a scoped capability
its server does not issue.

## What each server supports

| Source | How a stream request is authenticated | Scoped alternative available? | What a receiver ends up holding |
| --- | --- | --- | --- |
| **Jellyfin** | The session access token, in the URL's `api_key`. A receiver cannot send headers, so the credential has to be in the URL. | Not in the stable API: no per-item signed URL, no scoped download token, no server-side expiry to request. | An account credential that keeps working until the server revokes it. Signing out of Jellyfin in Linthra forgets the token here; it does not ask the server to invalidate it, so a receiver that kept the URL is unaffected until the user revokes that device in Jellyfin. |
| **Subsonic / Navidrome** | User name plus a salted token derived from the password, in the query, on every endpoint including streams. | Not through the Subsonic API. Navidrome has its own native API with shorter-lived tokens, but that is not the API Linthra speaks, and requiring it would break every other Subsonic server. | An account credential that does not expire on its own. It is derived from the password, so signing out here does not take it back either — only changing the password does. |
| **Plex** | The `X-Plex-Token` **header** — Linthra never puts it in a URL. Not wired for casting today. | Plex issues transient tokens, which bound the lifetime but are still account-scoped rather than per-item. | Would be a shorter-lived account credential, if casting ever routed through Plex. |
| **Audiobookshelf** | Bearer token. Not wired for casting today. | Not evaluated; it would need its own review before a cast resolver exists. | n/a |
| **On-device files** | Nothing: a receiver cannot reach a `file://` path, so these are not castable at all. | n/a | Nothing. |

So today, for both servers Linthra can cast from, the honest answer is
`accountCredential` / `account`. Saying otherwise — treating a token in a query
string as a capability, or adding a client-side expiry the server does not
enforce — would be inventing a restriction that only exists in our own code. A
receiver does not check it, and an attacker does not either.

Two things follow, and both are already true in the code:

- **Nothing else in the handoff carries the credential.** It rides on the
  `contentId` alone. Metadata does not carry it, `CastMedia.toString()` redacts
  the URL to scheme/host/path, the diagnostics API has no field for a token or a
  full URL, and error messages are generic by contract. Subsonic cover art is
  omitted for exactly this reason: it would carry the same credential for no
  playback benefit.
- **No broader credential is ever introduced as a fallback.** If a source cannot
  mint a castable URL, the track does not cast and the sheet says so. "Use the
  account credential instead" is not an error path.

## What would make this better

**Per-provider, upstream.** The change that actually helps is server-side: a
media endpoint that accepts a capability minted for one item, with an expiry and
independent revocation. For Jellyfin and Subsonic that is a server feature
request, not something a client can add. If either gains one, the work here is
small: declare `scopedCapability` on that resolver, mint it in the resolver, and
the model, tests and docs already have a place for it.

**Revoking on sign-out.** Signing out of a server in Linthra is local: the
credential is forgotten here, and the server is not asked to invalidate it. For
a handoff that has already happened, that is the difference between "the
receiver's copy stops working" and "it keeps working until the user goes and
revokes the device themselves". Jellyfin can revoke a session server-side, so
calling that on sign-out is a concrete, self-contained improvement — and a
change to sign-out behaviour for every user, not only those who cast, so it
belongs in its own change rather than riding along here. Subsonic has no
equivalent: its credential is the password.

**A media proxy on the device.** The app could stream from the server itself and
re-serve to the receiver over the LAN, so the server credential never leaves the
phone. It is a real option and it is not free:

- the proxy is an HTTP server on the user's network, which needs its own
  authentication — and the receiver has no way to authenticate to it, so
  whatever guards it is per-session and unguessable at best;
- it doubles the network traffic and keeps the phone awake for the whole track,
  which is exactly the cost casting exists to avoid;
- it needs a lifecycle: bound to the session, torn down on disconnect, on app
  exit, and on a crash, with nothing left listening afterwards;
- on Android it interacts with foreground-service and network-security policy.

Per #576 this gets its own security and operational review **before** any
implementation, not as part of a cast restoration. It is written down here so the
option is not rediscovered as a shortcut later.

**What is not on the table.** Client-side "restrictions" the server does not
enforce; sending a credential to a receiver that has not been authenticated
(regardless of scope); and weakening the model to keep a self-hosted deployment
working. Where a server simply cannot do better, the answer is to document the
limitation — as above — rather than pretend it away.

## If a scoped capability is ever added

Whatever mints it has to define, and test:

- **expiry** — short, server-enforced, and long enough only for the track;
- **revocation** — disconnecting or ending the session invalidates it, and the
  user can revoke it without touching their password;
- **cleanup** — nothing outlives the session: not in the catalog, not in a log,
  not in app state, not on disk;
- **redaction** — the same rule as today: the capability appears on exactly one
  field, and never in metadata, diagnostics, errors, or `toString()`.

And it still does not remove the receiver-authentication requirement.
