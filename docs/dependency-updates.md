# Dependency updates

Linthra checks its own dependencies on a schedule and prepares a pull request
when something can move. It never merges anything. The bot's job is to say
*"here is an update, and here is what CI thinks of it"*; deciding what happens
next is a human's (issue #362).

Three ecosystems are covered, by two different mechanisms:

| Ecosystem | Handled by | Cadence |
| --- | --- | --- |
| GitHub Actions | Dependabot — [`.github/dependabot.yml`](../.github/dependabot.yml) | weekly |
| Cargo (`native/linthra_core`) | Dependabot — same file | weekly |
| Dart / Flutter packages | [`dart-dependency-updates.yml`](../.github/workflows/dart-dependency-updates.yml) | weekly |

Toolchain updates — the Flutter SDK itself, Gradle, AGP, Kotlin, the JDK — are
not automated yet. They are separate phases of the same issue.

## Dart / Flutter packages

### What it does

Once a week (and on demand from **Actions → Dart dependency updates → Run
workflow**) the workflow checks out `main`, installs the pinned Flutter SDK and
runs:

```bash
flutter pub upgrade
```

That resolves every dependency to the newest version the constraints already in
`pubspec.yaml` allow, and writes the result to `pubspec.lock` — nothing else. If
the lockfile does not change, the run stops there and no PR is opened.

If it does change, the workflow:

1. asserts that `pubspec.lock` is the only file that moved,
2. re-checks the result with `flutter pub get --enforce-lockfile`,
3. runs `dart format`, `flutter analyze` and `flutter test`,
4. opens — or updates — a single draft PR on the `deps/dart-packages` branch.

Step 3 is reported, not enforced. A dependency that needs application changes
produces a red PR on purpose; see [Red PRs are the point](#red-prs-are-the-point).

### Why `flutter pub upgrade`, and not `--major-versions=false`

There is no `--major-versions=false`. `--major-versions` is a non-negatable
flag, and giving it a value fails outright:

```console
$ flutter pub upgrade --major-versions=false
Flag option "--major-versions" should not be given a value.
$ echo $?
64
```

The flag also does the opposite of what an automatic update wants: it *rewrites
the constraints in `pubspec.yaml`* so that majors can be pulled in. Plain
`flutter pub upgrade` is already the "newest compatible versions, no constraint
edits" command — `just_audio: ^0.9.42` cannot resolve to `0.10.0`, and
`permission_handler: ^11.3.1` cannot resolve to `12.0.0`. The rule is enforced
by the caret ranges a human wrote, which is exactly where that decision belongs.

One honest caveat: `pubspec.yaml` does not constrain *transitive* packages, so a
lockfile refresh can move them across major versions — the analyzer / build /
`source_gen` chain behind `drift_dev` is the usual example. That is what a
lockfile refresh is. It stays bounded by the pinned SDK and by what the direct
constraints admit, and it is a large part of why this ends in a reviewed PR
instead of a silent commit.

### Why not Dependabot

Dependabot does support the `pub` ecosystem, and using it would have been less
code. It cannot meet two of Linthra's requirements:

- **The pinned SDK.** Dependabot's pub updater resolves with its own bare Dart
  SDK and installs no Flutter at all. `pubspec.lock` is committed so the F-Droid
  build resolves the same dependency set we tested
  ([release-process.md](./release-process.md) §7), which means the lockfile has
  to come from the SDK in `.flutter-version`. The difference is not theoretical:
  resolving with the pinned SDK writes an `sdks:` block into the lockfile that
  names the Flutter line it was resolved against, which a Flutter-less resolver
  cannot produce.
- **Constraints must not move.** pub has no `lockfile-only` versioning strategy.
  All three strategies it offers — `widen`, `increase`, `increase-if-necessary`
  — rewrite the constraints in `pubspec.yaml`.

Dependabot keeps GitHub Actions and Cargo, where neither problem exists.
`test/tooling/dependency_update_guardrails_test.dart` fails if a `pub` ecosystem
is ever added to `.github/dependabot.yml`, so the two cannot start fighting over
the same lockfile.

### What the bot may touch

Exactly one file:

```text
pubspec.lock
```

Anything else fails the run before a commit exists.
`scripts/check_dependency_update_files.sh` owns that list, and it runs twice:
once inside the updater, and again in CI against the real PR diff for any
`deps/` branch — so a "just fix the failing test" commit pushed onto the update
PR afterwards is caught too.

In particular an automatic update never changes dependency constraints,
application code, test code, the app version, F-Droid metadata, Fastlane files,
release notes, signing files or licenses.

### Packages that deserve a closer look

The PR body calls these out by name when they move, because the Flutter checks
job cannot fully judge them — it does not build an APK, and it does not
regenerate the committed Drift output:

| Package(s) | Why |
| --- | --- |
| `just_audio`, `audio_service`, `audio_session` | Platform plugins behind playback, the media session and audio focus. Only a real Android build and a device exercise them. |
| `drift`, `drift_dev`, `sqlparser` | `drift_dev` generates the committed `*.g.dart`. If the generator's output changes, regeneration is an application change — run **Generate Drift files**, in its own PR. |
| `sqlite3`, `sqlite3_flutter_libs` | The native SQLite engine shipped in the APK; relevant to reproducibility. |
| `flutter_secure_storage` | Android Keystore-backed token storage. |
| `permission_handler` | Runtime `POST_NOTIFICATIONS` request. |
| `file_picker` | Native folder chooser. |
| `cast`, `bonsoir` | Chromecast transport and mDNS discovery, both F-Droid-safe by choice. |

This is a list of things to *read carefully*, not a resolution rule. Nothing
here needs special grouping: `pub upgrade` re-resolves the whole graph as one
consistent set, so packages that must move together already do, and a version
that would break a co-dependency is simply never selected.

### Red PRs are the point

If the update needs application changes, the PR stays red. That is the finding,
not a failure of the bot — the Flutter 3.44.7 upgrade is the worked example of
why blind auto-updates are not wanted here.

So the Flutter CI fixer is kept away from these branches. It skips `deps/*`
exactly the way it skips `dependabot/*`: while resolving the failed run, before
any repair is generated, and again in the publish job where the push would
happen. A repair commit would both hide which bump broke what and put
application code into a PR that is guarded to contain nothing but the lockfile.

### One-time setup

The workflow needs one repository Actions secret:

- `DEPENDENCY_UPDATE_TOKEN` — a dedicated fine-grained token with **Contents:
  read/write** and **Pull requests: read/write** on this repository.

This is the same pattern as `CI_FIXER_GITHUB_TOKEN` in
[flutter-ci-fixer.md](./flutter-ci-fixer.md), and for the same reason: a push or
a PR made with the workflow's default `GITHUB_TOKEN` does not trigger further
workflows, so the PR would open with no checks on it. An update PR that runs no
CI is a broken updater, so the workflow fails loudly rather than opening one —
but only when there is actually an update to publish. A week with no updates
never touches the token.

The job's own `GITHUB_TOKEN` stays `contents: read`.

### Reproducing it locally

The workflow runs the same script a contributor can:

```bash
./scripts/setup_flutter.sh
export PATH="$PWD/.tool/flutter/bin:$PATH"
./scripts/update_dart_dependencies.sh
```

It refuses to run against a Flutter that is not the pinned one, refuses to run
on a dirty tree (so every changed file is attributable to the run), and commits
nothing. Exit codes: `0` updated, `3` already up to date, `1` a guard failed.

Pass `--output-dir DIR` to also write the Markdown summary and the raw
`pub upgrade` log the workflow puts in the PR body.

### Reviewing an update PR

- Read the package list in the PR body, and the "needs a closer look" section.
- Check CI. Red is informative; work out *which* bump caused it.
- If it needs code changes, do that in a separate PR. Do not push the fix onto
  the update branch — the CI guard rejects it, and the next scheduled run
  refuses to force-push over commits it did not write.
- Merge manually when it is green and you are happy with it. Nothing
  auto-merges, by design.
