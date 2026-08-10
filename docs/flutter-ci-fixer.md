# Flutter CI fixer

Linthra has a guarded Codex-based repair workflow for failed **Flutter checks** jobs.

## What it does

When the `CI` workflow completes with a failure, the fixer inspects the run and only continues when the failing job is exactly `Flutter checks` and the source branch belongs to this repository.

For a same-repository pull request, a validated fix is committed back to that PR branch so the normal CI runs again. For a failed push to `main`, the fixer opens a dedicated `codex/ci-fix-*` pull request. It never merges automatically.

The agent gets at most two repair attempts. A patch is published only after all of these pass on the runner:

```text
flutter pub get --enforce-lockfile
dart format --set-exit-if-changed .
flutter analyze
flutter test
./scripts/check_secrets.sh
```

## One-time setup

Add a repository Actions secret named `OPENAI_API_KEY`. The workflow uses the official `openai/codex-action@v1` action. If the secret is absent, the fixer stays installed but safely does nothing and emits a notice.

The repository must also allow GitHub Actions to write repository contents and pull requests. Linthra already uses write-capable release automation, so keep the existing repository policy consistent with that setup.

## Safety boundaries

The fixer skips fork PRs and refuses to process its own `codex/ci-fix-*` branches, preventing an automatic repair loop.

The Codex job itself only receives read permissions. It cannot push. A separate publish job receives write permissions only after a patch has passed the full local verification gate.

The publish guard rejects changes to protected areas including:

- `.github/`
- license files
- `pubspec.yaml` and `.flutter-version`
- F-Droid/store metadata and release notes
- secret-scan policy
- analyzer policy
- signing keys and keystore configuration

The prompt also forbids deleting/skipping tests, weakening assertions, blanket ignores, telemetry, version bumps, releases, and unrelated refactors.

If the source branch moves while the fixer is working, publication is aborted instead of pushing a stale patch.

## Manual retry

The workflow also supports `workflow_dispatch`. Open **Actions → Flutter CI fixer → Run workflow** and provide the numeric ID of a failed `CI` run. The same trust, validation, and publication rules apply.
