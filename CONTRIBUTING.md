# Contributing

## As a human

1. Read `PROJECT.md` and `factory/RULES.md`.
2. Open a request as a GitHub Issue. Intake drafts a ticket from it; the weekly desk
   approves or rejects. Requests that cannot cite a `PROJECT.md` line are rejected.
3. If you want to run a node: `git clone`, then `/factory:join` inside Claude Code. The
   wizard prints what it will install before it installs it.
4. Human-authored PRs take the same gates and the same prosecution as agent PRs. No
   exemption.

## Sign-off and disclosure

Every commit carries a DCO sign-off from a human (`git commit -s`):

    Signed-off-by: Your Name <you@example.com>

By signing off you certify the [Developer Certificate of Origin 1.1](https://developercertificate.org/).

Every commit an agent produced also carries the adapter that produced it, so the
project's AI-contribution disclosure is machine-checkable:

    Assisted-by: claude-code@2.1.280

The run loop adds this trailer; CI (`commit-check`) refuses a commit without it on a
`ticket/**` branch.

## Provider terms

Each node owner runs their own coding-agent CLI under their own subscription. Compliance
with that provider's terms is the owner's responsibility; nothing in the factory depends on
a particular reading of them. The factory never holds a shared API key.

## Outbound PRs

Before any PR leaves this project for another repo, the desk's policy check reads the
target's AI-contribution policy. A ban is a hard stop; a disclosure requirement means the
`Assisted-by:` trailer and a one-line note in the PR body.

## Desk duty

One person per week, odd-numbered rotation, listed in `factory/DESK.md` once there are
three volunteers. That week they do not run a node.
