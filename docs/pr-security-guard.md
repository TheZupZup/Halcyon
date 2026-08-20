# PR security surface guard

`.github/workflows/pr-security-review.yml` decides whether a pull request
crosses a trust boundary that deserves an explicit maintainer security review,
and hard-rejects a small set of unusually powerful additions. The classifier
lives in `scripts/check_pr_security_surface.py`; its tests are
`test/tooling/check_pr_security_surface_test.py`.

## What it does

- **Ordinary PRs pass untouched.** UI, tests and docs changes produce
  `sensitive=false` and the gate is a no-op.
- **Sensitive surfaces need a review.** Changes to CI, automation scripts,
  dependency manifests, Android permissions, native Linux code, or to
  auth/network/persistence code — and added behaviour such as new network
  clients, filesystem writes or database migrations — require **TheZupZup to
  have approved the exact current HEAD**. Pushing a new commit changes the
  HEAD, so the previous approval no longer applies.
- **A few additions are rejected outright.** Runtime process/shell execution,
  FFI and dynamic library loading, the privileged pull-request trigger variant
  (`pull_request` + `_target`), Actions `write-all` permissions, and
  download-and-execute shell patterns are not bypassable by approval. If
  Linthra genuinely needs one of these, it should land as its own
  maintainer-controlled change, not inside an unrelated contributor PR.
- **The scanner comes from the trusted base.** The workflow reads
  `scripts/check_pr_security_surface.py` out of the PR's base commit, so a PR
  cannot weaken the classifier in the same change it is trying to pass.
- **It fails closed.** A missing base commit, an undecodable diff header, a
  scanner crash, or a scan that ends without a verdict all fail the job.

The workflow holds only `contents: read` and `pull-requests: read`, receives no
repository secrets, and never executes contributor code.

## Required repository configuration

> **The workflow cannot enforce this part itself.** Configure it once, in
> repository settings.

For `pull_request` events GitHub evaluates the workflow definition from the
PR's merge ref. A contributor can therefore edit
`.github/workflows/pr-security-review.yml` in their own PR — keeping the
workflow name and the `Security surface guard` job name while replacing the
steps with something that trivially succeeds. A required status check matched
**by name** would accept that green result even though the trusted scanner
never ran.

To close it, the guard has to run from a definition the PR cannot edit:

1. Open **Settings → Rules → Rulesets** and add a ruleset targeting the default
   branch.
2. Enable **Require workflows to pass before merging**.
3. Add `.github/workflows/pr-security-review.yml` from **this repository**,
   pinned to a trusted ref (`main`, or a tag/SHA you bump deliberately).
4. Keep **Require status checks to pass** enabled as well, so the check is
   both required and sourced from the trusted definition.

With the ruleset in place, editing the workflow inside a PR no longer changes
what runs for that PR. Without it, the classifier is still loaded from the
trusted base — but the surrounding gate is only as trustworthy as the PR's own
copy of the workflow.

Changes to the guard's own files are classified sensitive, so an external PR
touching them needs a maintainer security review regardless.

## Bootstrap

The first PR to introduce the scanner cannot load it from a base that does not
contain it yet. In that single case the workflow falls back to the PR head's
copy, and only when the PR author is the repository owner **and** the head
branch lives in this repository. An external PR whose base lacks the scanner
fails closed instead. Once the scanner is on `main`, this path is unreachable.

## Working on the guard

Run the tests directly:

```sh
python3 test/tooling/check_pr_security_surface_test.py
```

They build synthetic git repositories for every classification and blocked
pattern, cover the diff-rendering tricks that would otherwise hide an added
line (quoted pathnames, `.gitattributes` `-diff`, renames, constructs split
across lines and hunks), and execute the workflow's own trusted-scanner loader
and review-decision filter straight out of the YAML.

One constraint is easy to trip over: the guard scans every added line of every
changed file, **including its own sources**. A blocked pattern written out in
full in the scanner, the workflow, or the tests would make the guard reject any
PR that touches the guard. `_split_literal()` in the scanner and `blocked()` in
the tests assemble those literals from fragments, and
`GuardSelfSafety` fails the build if a contiguous one ever creeps back in.
