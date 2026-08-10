# Flutter CI fixer

Linthra has a guarded Codex-based repair workflow for failed **Flutter checks** jobs.

## What it does

When the `CI` workflow completes with a failure, the fixer inspects the run and only continues when the failing job is exactly `Flutter checks` and the source branch belongs to this repository.

For pull requests, the fixer diagnoses and verifies against the exact synthetic merge revision that failed in GitHub Actions, while tracking the raw PR head separately for safe publication. If either the PR head or its base branch has advanced since the failed run, the fixer stops instead of applying stale logs to newer code.

For a same-repository pull request, a validated fix is committed back to that PR branch. For a failed push to `main`, the fixer opens a dedicated `codex/ci-fix-*` pull request. It never merges automatically.

The agent gets at most two repair attempts. A patch is published only after all of these pass on the runner:

```text
flutter pub get --enforce-lockfile
dart format --set-exit-if-changed .
flutter analyze
flutter test
./scripts/check_secrets.sh
```

## One-time setup

Two repository Actions secrets are required:

- `OPENAI_API_KEY` — used only by the read-token Codex repair job.
- `CI_FIXER_GITHUB_TOKEN` — a dedicated fine-grained GitHub token used only by the separate publication job.

The publication token must be able to push branches and create/comment on pull requests. For a fine-grained personal access token, grant repository access to Linthra with **Contents: read/write**, **Pull requests: read/write**, and **Issues: read/write**. Do not give this token to the Codex job.

A dedicated publication token is intentional: pushes or PRs created with the workflow `GITHUB_TOKEN` do not trigger normal follow-up workflows. Publishing with `CI_FIXER_GITHUB_TOKEN` lets GitHub run the repository's standard `pull_request`/`push` CI naturally on the repaired commit instead of relying on a manual-dispatch workaround.

If `OPENAI_API_KEY` is absent, the fixer safely no-ops with a notice. If a repair is validated but `CI_FIXER_GITHUB_TOKEN` is absent, publication fails before any repository write occurs.

## Safety boundaries

The fixer skips fork PRs and refuses to process its own `codex/ci-fix-*` branches, preventing an automatic repair loop.

The Codex job itself only receives read permissions. It cannot push. The publication credential is available only in the separate publish job after a patch has passed the full local verification gate.

The publish guard rejects changes to protected areas including:

- `.github/`
- license/copyright notice files at any path depth
- `pubspec.yaml` and `.flutter-version`
- F-Droid/store metadata and release notes
- secret-scan policy
- analyzer policy
- signing keys and keystore configuration

New files are marked intent-to-add before each secret scan so generated files are scanned before a patch can be published.

The prompt also forbids deleting/skipping tests, weakening assertions, blanket ignores, telemetry, version bumps, releases, and unrelated refactors.

If the source PR head or base branch moves while the fixer is working, publication is aborted instead of pushing a stale patch. The validated patch is applied to the raw PR head without force; if it no longer applies cleanly, publication fails safely.

## Manual retry

The workflow also supports `workflow_dispatch`. Open **Actions → Flutter CI fixer → Run workflow** and provide the numeric ID of a failed `CI` run. The same trust, stale-state, validation, and publication rules apply.