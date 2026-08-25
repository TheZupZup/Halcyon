# Repository hardening

Linthra uses two independent pull-request security gates:

- **Security surface guard** classifies sensitive code and requires an explicit
  owner review for risky trust-boundary changes.
- **Repository integrity guard** fails closed on repository-control changes and
  disguised executable assets.

The repository-integrity layer was added after a real PR-history incident in
which an unrelated commit carried IDE auto-run configuration and executable
JavaScript disguised as a `.woff2` asset. The goal is prevention, not
attribution: Git history can establish provenance and branch movement, but not
a person's intent.

## What the repository integrity guard blocks

For external contributor PRs:

- `.vscode/**`, `.idea/**`, and `*.code-workspace`
- `.github/workflows/**` and composite actions under `.github/actions/**`, which
  privileged workflows run from the PR head
- repository automation under `scripts/`, `tool/`, and `tools/`
- `CODEOWNERS`, `.gitattributes`, `.gitmodules`, and Dependabot policy
- Git symlinks

For every PR, including maintainer PRs:

- removal of `.idea/` or `.vscode/` from the root `.gitignore`, including a
  later `!` rule that re-enables one of them (Git applies the last matching
  rule, so presence of the entry alone proves nothing)
- files whose extension claims WOFF/WOFF2/TTF/OTF/PNG/JPEG/GIF/WEBP but whose
  contents are not structurally that format. A magic prefix is not enough:
  `wOF2` followed by JavaScript is four valid bytes, so each format is checked
  against a self-describing field — a declared length that must equal the real
  file size, or a redundant field derived from another
- active/executable SVG content such as `<script>`, any `on*=` event handler,
  `javascript:` URLs, `foreignObject`, or external executable references. The
  scan runs over the raw source, the entity-decoded text, and a URL-normalised
  form, since an XML parser resolves `java&#x73;cript:` and a URL parser then
  discards embedded tabs and newlines
- asset files committed with the executable bit set. The text scan only sees an
  invocation someone wrote down; a payload committed already-executable needs
  none
- text that invokes an asset such as `.woff2`, `.png`, or `.pdf` through
  Node/Python/shell interpreters, or marks one executable with `chmod +x`

Repository-control changes must be made from a trusted maintainer-controlled
branch.

## Self-test fixtures

The guard's own test module has to contain literal attack strings so it can
assert that they are caught, which would otherwise make the repository-wide
text scan flag the test file itself.

The carve-out for this is deliberately small. A line inside
`test/tooling/check_repository_integrity_test.py` is skipped by the
asset-execution text scan — and by that check only — when it carries the
marker `integrity-guard-fixture`. Every other line of that file, and every
other check, still applies, and the same path is maintainer-controlled for
external PRs so a fork cannot introduce a marked line. Fixture content written
into a test repository carries no marker, so the attack strings the tests
assert against remain detectable.

Prefer this marker over path-wide exclusions: `test/` and `test/tooling/` stay
fully scanned, because executable test infrastructure is itself a security
surface.

## Where the asset checks stop

Container validation raises the cost of disguising an executable as an asset;
it does not close the class. The honest boundary:

- **Binary formats** (WOFF/WOFF2, TrueType/OpenType, PNG, JPEG, GIF, WEBP, ICO)
  are validated structurally end to end — declared lengths must match, chunk and
  block chains must land exactly on the end of the file, and an image must carry
  a real bitstream signature. Polyglots against these are hard.
- **PDF is different.** A shell reads a file line by line and continues past
  errors, so only the opening lines decide what runs. No amount of trailing
  xref, trailer or object structure prevents a payload on line two, and a
  genuine PDF is itself "runnable" that way as a series of failing commands.
  Parsing the object graph would buy nothing here, so the PDF check is a
  deliberate sanity layer only.

What actually defends a disguised asset is denying it an execution path:

- assets may not carry the executable bit
- no file in the repository may invoke one through an interpreter
- IDE and container auto-run surfaces are maintainer-controlled

Treat those three as the real control, and the format validators as depth.

## Required GitHub ruleset for `main`

Create or update a branch ruleset targeting `main` and configure all of the
following:

1. **Require a pull request before merging**
   - required approvals: **1**
   - **Dismiss stale pull request approvals when new commits are pushed**
   - **Require review from Code Owners**
   - **Require approval of the most recent reviewable push**
   - **Require conversation resolution before merging**
2. **Block force pushes**
3. **Restrict deletions**
4. **Require status checks to pass before merging**
   - `Flutter checks`
   - `Secret & privacy scan`
   - `Build Linux desktop`
   - `Security surface guard`
   - `Repository integrity guard`
5. Do not give ordinary contributors a ruleset bypass.
6. Prefer an empty bypass list; if an emergency bypass is retained, keep it to
   the repository owner only.

### Required-workflow pinning

A status check matched only by name is not enough for a security workflow:
a contributor can edit a workflow file in the same PR and attempt to preserve
the job name while replacing its steps.

Use a GitHub **required workflow / ruleset workflow requirement pinned to the
trusted repository and default branch** for:

- `.github/workflows/pr-security-review.yml`
- `.github/workflows/repository-integrity.yml`

This ensures the trusted workflow definition is what evaluates the PR.

## Actions settings

Under **Settings → Actions → General**:

- keep the default `GITHUB_TOKEN` permission **read-only** unless an individual
  workflow explicitly needs more
- leave **Allow GitHub Actions to create and approve pull requests** disabled
  unless a documented maintainer workflow needs it
- require approval before workflows from untrusted fork contributors run, using
  the strictest option that still fits the project workflow
- never attach repository secrets to untrusted `pull_request` jobs

## Contributor model

External contributors should work from their own forks. Avoid granting `Write`
access to the upstream repository merely to make contribution easier.

For fork PRs:

- keep branch ownership isolated in the contributor's fork
- only use **Allow edits from maintainers** when a maintainer actually needs to
  repair that contributor's branch
- after any force-push, re-review the current HEAD; previous approval must not
  carry forward

## Incident response

If a PR contains unexpected executable content:

1. do not run the branch locally
2. close or quarantine the PR
3. record commit SHA, author/committer metadata, branch force-push events, and
   the exact suspicious files
4. compare the suspect commit with its parent to identify provenance
5. rebuild useful feature work from a known-clean base instead of "cleaning"
   the contaminated branch
6. rotate secrets only if evidence shows they may have been exposed
7. avoid attributing intent unless there is evidence beyond Git metadata
