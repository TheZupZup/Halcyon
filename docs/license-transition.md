# Planned license transition: MPL-2.0 to AGPL-3.0-or-later

## Status

**Proposed. Do not treat Linthra as AGPL-licensed yet.**

The repository is currently licensed under MPL-2.0. Existing releases remain under the
license terms that applied when they were published.

The intended target for future Linthra releases is **AGPL-3.0-or-later**, once the
project has confirmed that all copyrighted contributions needed for the transition may
be relicensed on those terms.

This document exists so the decision, rationale, migration surface, and remaining legal
work are explicit rather than being hidden in a one-line LICENSE replacement.

## Why move to AGPL-3.0-or-later

Linthra is meant to stay open source when other projects build directly on it.
MPL-2.0 uses file-level copyleft, which intentionally allows MPL files to be combined
with separately licensed proprietary files. That flexibility is useful for many
projects, but it is weaker than the policy Linthra now wants for downstream derivatives.

AGPL-3.0-or-later is the intended direction because it provides strong copyleft for
covered derivative works and also contains the network-interaction source offer that
distinguishes AGPL from GPL.

The goal is not to prevent forks. Forking, modifying, studying, and redistributing the
software should remain possible. The goal is that a project which actually builds on
Linthra should not be able to take the shared work, turn the resulting covered work into
a closed product, and keep the corresponding source unavailable to its users.

## What this does not solve by itself

A stronger software license does **not** make third-party binaries trustworthy.
Someone can still publish a modified build, and an open-source license cannot guarantee
that the modification is safe or malware-free.

That is why the license transition is paired with [`TRADEMARKS.md`](../TRADEMARKS.md):
modified builds must not be presented as official Linthra releases. Signed official
builds and clear distribution channels remain the practical way for users to distinguish
what the Linthra project actually shipped from third-party modifications.

Likewise, neither AGPL nor the branding policy is a promise that legal claims can never
be made against a maintainer. They are intended to make ownership, source obligations,
origin, warranty boundaries, and responsibility for third-party modifications clearer.

## Why the repository is not being relabeled immediately

Linthra has accepted contributions from copyright holders other than the repository
owner. The current contribution terms say that contributions are licensed under
MPL-2.0.

MPL 2.0 has compatibility rules for combining MPL-covered code with GPL-family code,
but Mozilla's own guidance explicitly distinguishes that mechanism from simply deciding
to relicense an existing MPL project as GPL/AGPL-only. A clean project-wide transition
therefore needs the relevant copyright permissions rather than silently replacing the
license on somebody else's contribution.

Before the AGPL switch is merged, maintainers should identify non-trivial external
copyright contributions and record explicit relicensing consent where required. The PR
or a linked issue is a good permanent place to record those approvals.

References:

- MPL 2.0 FAQ: https://www.mozilla.org/en-US/MPL/2.0/FAQ/
- Mozilla's MPL/(L)GPL combination guidance:
  https://www.mozilla.org/en-US/MPL/2.0/combining-mpl-and-gpl/
- GNU AGPL v3: https://www.gnu.org/licenses/agpl-3.0.html

## Migration checklist

After contributor permissions are confirmed, make the actual license switch in one
reviewable change:

- replace the top-level `LICENSE` with the unmodified GNU Affero General Public License
  version 3 text and state the project choice as `AGPL-3.0-or-later`;
- change the README license badge and current License section;
- update `CONTRIBUTING.md` so new contributions are accepted under the same AGPL terms;
- update the in-app About screen and its tests;
- update `native/linthra_core/Cargo.toml`;
- update the repository's F-Droid metadata to `License: AGPL-3.0-or-later`;
- update current F-Droid/readiness/submission documentation without rewriting historical
  release facts;
- update current Play Store/listing documentation where it identifies the project
  license;
- update any current generated/static documentation pages that display MPL-2.0;
- run a repository-wide search for `MPL-2.0`, `MPL 2.0`, and `Mozilla Public License`
  before merge so no active metadata is missed; and
- leave historical release notes unchanged when they accurately describe releases that
  were actually published under MPL-2.0.

The current repository-wide search already identifies active references in, among other
places:

- `README.md`
- `CONTRIBUTING.md`
- `metadata/io.github.thezupzup.linthra.yml`
- `native/linthra_core/Cargo.toml`
- `lib/features/settings/hub/about_screen.dart`
- `test/features/settings/hub/about_screen_test.dart`
- `docs/fdroid-build-recipe.md`
- `docs/fdroid-readiness.md`
- `docs/fdroid-submission.md`
- `docs/play-store-listing.md`
- `docs/play-store-readiness.md`
- `docs/index.html`
- `docs/privacy.html`

## F-Droid

AGPL-3.0-or-later is a free-software license suitable for F-Droid metadata. The license
change does not require changing Linthra's application ID or signing model.

The important migration detail is version history: old Linthra source tags and old
F-Droid builds remain MPL-2.0. The F-Droid metadata should be updated for the first
release that is actually published under AGPL-3.0-or-later, and the corresponding source
tag must contain the matching license state.

Do not retroactively edit old release notes to say AGPL when those releases shipped
under MPL.

## Branding and unofficial builds

The software license and project identity are deliberately separate.

AGPL controls the terms under which covered source and derivative works are distributed.
[`TRADEMARKS.md`](../TRADEMARKS.md) controls whether a third-party build may present
itself using Linthra's official identity.

For a modified downstream build, the expected rule is simple: keep the source open as
required by the applicable software license, and use a distinct name/branding so users
do not mistake that build for one reviewed and published by the Linthra project.
