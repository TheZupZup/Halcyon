# Relicensing consent tracker

Linthra is currently distributed under MPL-2.0. The project intends to move
future releases to **AGPL-3.0-or-later**, but the project-wide license will not
be changed until the copyright permissions needed for that transition are
confirmed.

This file is a public record of that process. It is not itself a license, it does
not change the license of any existing Linthra release or contribution, and it is
not legal advice.

## What the consent is meant to do

The intent is **additive**. A contributor who agrees is not withdrawing the
MPL-2.0 terms under which their work was originally contributed, and is not
transferring ownership of their copyright. They are granting permission for the
same work to **also** be distributed by the project under AGPL-3.0-or-later.

## Consent statement

A contributor who agrees to the transition may record the following statement in
the pull request or issue that tracks the relicensing:

> I am the copyright holder of, or am otherwise authorised to license, my
> contributions to the repository `TheZupZup/Linthra`.
>
> I grant TheZupZup and the Linthra maintainers permission to license and
> distribute my contributions to that repository — those I have already made and
> any I make in future — under **AGPL-3.0-or-later**, in addition to, and without
> withdrawing, the MPL-2.0 terms under which they were originally contributed.
>
> I understand that this permission extends to downstream recipients under the
> terms of that license, and that it does not transfer ownership of my copyright.

The agreement should come from the contributor's own GitHub account so there is
a durable, attributable record.

## Known contributor status

| Contributor | Status | Notes |
| --- | --- | --- |
| TheZupZup | approved | Project owner / initial contributor; proposed the transition. |
| @jpdexter101-lang | pending | Human contributor with copyrightable contributions merged under MPL-2.0; request explicit consent before the project-wide AGPL switch. |
| Other human contributors | audit before merge | Review repository history before the final license replacement so nobody with relevant copyright ownership is silently skipped. |

For each contributor, record the GitHub handle, a permalink to the comment
granting consent, and the date.

## Auditing who needs to be asked

A GitHub contributor count is not sufficient on its own. In particular it does
not surface `Co-authored-by:` trailers, which is where contributions made through
squash-merged pull requests and accepted review suggestions appear.

When running the audit, distinguish:

- human-authored code from automated commits (dependency bots, CI accounts);
- surviving code from code that has since been deleted or rewritten, since only
  what still ships needs relicensing;
- generated and vendored content from original contributions.

Note that vendored third-party code keeps its own license. `third_party/` is not
covered by this transition and must not be relabelled.

Automated tooling, dependency-update bots, and generated/co-authored metadata
should not be treated as a substitute for auditing the actual human copyright
holders of contributed code.

## If a contributor refuses, cannot be reached, or does not respond

**Do not treat silence as consent.** A contributor who does not reply has not
agreed, and their contributions must be handled as though consent were withheld.

The project-level options, none of which should be chosen without care:

- **Obtain the permission.** Continue trying to reach the contributor through the
  contact routes they have made available, and allow a reasonable time for a
  reply before concluding that they are unreachable.
- **Remove or rewrite the affected contributions.** Replace the relevant work so
  the code being relicensed no longer depends on a contribution the project does
  not have permission to relicense. What counts as a sufficient rewrite is a
  judgement call and should be made deliberately rather than assumed.
- **Do not switch.** Leaving the project on MPL-2.0 remains a valid outcome. The
  transition is a preference, not an obligation, and it is better not to switch
  than to switch on an unclear footing.

If the situation is unclear, seek appropriate professional advice before
proceeding rather than resolving the ambiguity in the project's own favour.

## Merge rule for the actual license switch

Do not replace the top-level `LICENSE` or advertise the repository as
AGPL-3.0-or-later until the maintainer has completed the contributor audit and
recorded the permissions needed for the intended project-wide relicensing.

Historical releases remain under the terms that applied when they were
published.
