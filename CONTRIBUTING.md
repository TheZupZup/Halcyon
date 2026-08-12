# Contributing to Linthra

Hey — thanks for being here. Linthra is a self-hosted Android music player, and
this is a great time to get involved. Small changes can still shape the project
in a real way.

**You do not need to know Dart or Flutter to contribute to Linthra.** Testing the
app, improving docs, reporting bugs, or working in one of the native/tooling
areas are all real contributions.

If you're not sure where to start, check the
[issue tracker](https://github.com/TheZupZup/Linthra/issues). Issues tagged
**`good first issue`** are intentionally kept approachable, and **`help wanted`**
shows where an extra pair of hands would help most.

## Pick the language you know

Linthra uses different languages where they have a real technical job. Pick the
area that matches what you already know:

| Language | Good place to contribute |
| --- | --- |
| **Dart / Flutter** | UI, player orchestration, providers, onboarding, app logic |
| **Kotlin** | Android APIs, SAF/MediaStore, media session, Android Auto, platform channels |
| **Rust** | large-library indexing/search and future 100k–200k-track primitives |
| **C++** | realtime audio DSP, EQ/limiting, future audio analysis and SIMD |
| **Python** | releases, developer tooling, fixtures, benchmarks, validation |
| **SQL** | SQLite indexes/query plans and very-large-library performance |

The detailed map and boundaries are in
[Contributing by language](./docs/language-areas.md). A language should only be
used when it has a real technical role in the project.

## Setting up the project

For Dart/Flutter/Android work, the normal setup is:

```bash
./scripts/setup_flutter.sh
./scripts/verify_android.sh
```

`setup_flutter.sh` installs or reuses the pinned Flutter version without sudo.
`verify_android.sh` runs the main Flutter checks and can build a debug APK when
an Android SDK is available.

Full setup details and troubleshooting are in
[docs/development.md](./docs/development.md). The
[codebase tour](./docs/codebase-tour.md) is useful if you want a map of where
features live before changing anything.

Native/tooling areas have their own focused commands and CI:

- `native/linthra_core/` uses Cargo.
- `native/linthra_audio/` uses CMake.
- `tools/large_library/` contains Python/SQLite tooling for large-library work.

## Picking something to work on

- Comment on an issue before starting so two people don't unknowingly do the
  same work.
- Keep independent problems in separate issues when they can be fixed
  separately. It makes them easier to understand, review, assign, and close.
- If several problems are really one bug or one flow, one issue with a short
  checklist is fine.
- Opening a small PR for something not yet tracked is okay too — just explain
  what changed and why.

## Pull requests

- **Keep PRs small and focused.** One change per PR is much easier to review and
  merge than a big bundle.
- **Write a clear description** with what changed and why. Link the issue it
  closes when there is one.
- **Add tests when it makes sense**, especially for bug fixes and new logic.
- **No unrelated changes.** Don't reformat or refactor nearby code unless it is
  part of the same job.
- Run the relevant verification command before pushing.

## Code style

Nothing exotic — just code that's easy to read and maintain:

- **Readable over clever.** Clear names and straightforward control flow win.
- **Modular.** Keep files and functions focused.
- **No premature abstraction.** Add a shared layer when there is a real reason
  for it, not just because two lines look similar.
- **Comment the why, not the what.** Explain non-obvious decisions rather than
  narrating obvious code.

## Privacy & security

A few rules are non-negotiable:

- **Never log tokens, passwords, or secrets.**
- **Don't persist authenticated URLs.** Stream URLs must not end up in logs,
  diagnostics, or long-term storage.
- **Keep credentials encrypted at rest.**
- **No telemetry or phoning home.** Nothing should leave the device unless the
  user explicitly chooses it.

If a change touches authentication, streaming, diagnostics, or stored
credentials, mention the security impact in the PR description so it is easy to
review.

## Testing

Some behaviour only shows up properly on a real phone, server, Cast receiver, or
Android Auto setup. If your PR touches one of those areas and you can test it on
real hardware, please say what you tested in the PR.

The [manual QA checklist](./docs/manual-test-checklist.md) covers the important
paths. For bug reports, **Settings → Report a bug** can build a secret-free
report you can review before opening an issue.

## Supporting contributors

Linthra is open source and contributions are currently voluntary, but I don't
want the project to grow while pretending the people helping build it don't
matter.

If Linthra eventually receives enough recurring donations or sponsorships to
make it sustainable, I plan to create a public contributor sponsorship program
and share part of that funding with people who meaningfully help the project.

The exact system would be designed transparently when we actually reach that
point, because I want it to stay fair and sustainable for everyone.

For now I can't promise payment for a contribution, but if Linthra becomes
financially successful, my goal is not to keep all of that support for myself
while other people are helping build it.

## License

Linthra is [MPL-2.0](./LICENSE). By contributing, you agree your contributions
are licensed under the same terms.

Thanks again — see you in the issues.
