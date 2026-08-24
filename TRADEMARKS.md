# Linthra name, logo, and official builds

Linthra's source code is distributed under the software license in [`LICENSE`](./LICENSE).
That software license does **not** grant permission to present a modified build as an
official Linthra release, or to imply endorsement by the Linthra project.

This document is about project identity and distribution, not about restricting the
freedoms granted by the software license. Forks, modified builds, independent
distributions, and downstream packaging are all welcome. The only thing this policy
asks is that users can tell who built and published the thing they installed.

## Official Linthra builds

A build may be described as an **official Linthra build** only when it is distributed
by the Linthra project through an official project channel, or when it is an unmodified
redistribution of an official project binary and is clearly identified as such.

Official project channels currently include the Linthra GitHub repository and releases.

Different distribution channels may build and sign packages differently, and a
package's signing identity is a property of the channel that published it. For the
signing details of a specific channel — including which key signs the packages it
distributes — see the project's release and distribution documentation rather than
assuming that packages carrying the same name are interchangeable between channels.

## Referring to Linthra

You do not need permission to refer to Linthra by name. That includes, but is not
limited to:

- articles, reviews, comparisons, and other commentary;
- compatibility and interoperability documentation;
- package descriptions, store listings, and changelogs; and
- truthful statements such as "based on Linthra", "a fork of Linthra", or
  "compatible with Linthra".

Truthful attribution is always welcome. This policy is only concerned with uses that
could mislead a user about **who produced a build** or **who is responsible for it**.

## Independent distributions

Some distributors build and publish Linthra themselves rather than redistributing a
binary the project produced. F-Droid, Flathub, and Linux distribution repositories are
the usual examples.

**Building Linthra from its published source and distributing the result under the
Linthra name is welcome.** Doing so does not by itself make a build a modified fork, and
does not require a different name, icon, or application identifier.

An independent distribution should:

- make the package origin clear, so users can tell which distributor built and
  published the package they installed;
- not claim that its own build or signing infrastructure is the Linthra project's own
  official release infrastructure; and
- follow the rule on packaging changes below.

## Packaging and platform-integration changes

Changes limited to packaging, build configuration, dependency handling, platform
integration, or distribution metadata — the kind of patch a distribution applies so
that Linthra builds and runs correctly on its platform — do not by themselves
materially change Linthra's user-facing identity or behaviour, and therefore do not by
themselves require a different application name, icon, or application identifier.

The practical test is whether a user could reasonably be misled about what they
installed and who is responsible for it. Patching a build flag, adjusting dependency
packaging, or adding platform integration does not mislead anyone. Changing what the
app does, how it handles user data, or where it connects to, does.

## Modified builds and forks

You are welcome to fork, study, modify, and redistribute Linthra under the terms of its
software license.

If you distribute a build that goes beyond the packaging changes described above — one
that materially changes Linthra's behaviour or user-facing identity — you should make it
clear that the build is not an official Linthra release. In particular, such a
distribution should:

- use a different application name and visual identity;
- use its own application/package identifier when practical;
- not use the Linthra logo as the primary icon or branding for the modified app;
- not call itself "official Linthra" or otherwise imply endorsement by the Linthra
  project or its maintainers; and
- clearly state that it is a third-party fork or modified build based on Linthra.

## Unmodified redistribution

Redistributing an unmodified official Linthra binary is allowed when the applicable
software license permits it. The distributor should preserve the original notices and
make the source and origin of the binary clear.

A mirror or app store that redistributes Linthra should distinguish the **developer**
from the **uploader/distributor**. A third-party uploader must not be presented as the
original Linthra developer.

## Security and user trust

The purpose of this policy is to help users distinguish official releases from modified
third-party builds. A modified build can contain behaviour that the Linthra maintainers
have never reviewed, including security-sensitive changes.

The Linthra project is responsible only for builds and source code it actually publishes
or explicitly endorses. Third-party distributors and fork maintainers are responsible
for their own modifications, packaging, signing, claims, and support. This is a
statement about responsibility, not a suggestion that independent distributions are
untrustworthy — a distribution that builds Linthra from source and says so plainly is
exactly what this policy is meant to protect.

Users should prefer a trusted distribution channel and should not assume that two APKs
or packages named "Linthra" are identical merely because they share a name or icon.

## Brand assets and the software license

The software license in [`LICENSE`](./LICENSE) grants rights in the project's source
code and in the files distributed with it.

Whether something may be presented as an official Linthra release, or use the Linthra
name and logo in a way that suggests the project produced or endorsed it, is a separate
question from that copyright license. This document addresses only the second question.

## Permission and questions

If a redistribution, port, downstream package, or integration needs to use the Linthra
name or logo in a way not covered here, open an issue in the official repository. You do
not need to ask first in order to refer to Linthra truthfully (see
[Referring to Linthra](#referring-to-linthra)), to package Linthra for a distribution,
or to publish a clearly-identified fork.

This policy does not claim registration of any trademark and does not assert rights
beyond those that may exist under applicable law. It does not restrict what the software
license permits. It simply states the Linthra project's conditions for using its project
identity in ways that could imply origin or endorsement.
