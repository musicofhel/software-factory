# PROJECT.md — charter

Every ticket must cite a line of this file. Intake rejects, and the desk does not rescue,
a ticket that cannot.

## What

A distributed software factory: a public GitHub repo plus a pull-based fleet of members'
laptops that turns an approved ticket into a merged, prosecuted, human-accepted PR with
no coordinator process and no shared API key. Spec: `docs/spec/SPEC-v0.2.txt`.

## This quarter we ship

**The factory itself, through build order steps 1–6, and then open the queue (step 7).**
The factory is its own first project. Until step 7, the only tickets are `factory/`
tickets.

## Scope

- C1. The three state machines (ticket, node, claim) exactly as the spec's tables state them.
- C2. The claim protocol: a git ref under `refs/locks/issue-N` created by the GitHub API is
  the one compare-and-swap; the Issue assignee is display only.
- C3. The clock and janitor: an hourly Action that owns every time-driven transition.
- C4. The kill switch: `factory/HALT` on `main`; present means every loop sleeps.
- C5. The join wizard, node manifest, and run loop, on any Linux, macOS or WSL2 box with
  8 GB+ RAM and one authenticated coding-agent CLI.
- C6. CI gates that rerun every deterministic check because a laptop is not a trust boundary.
- C7. Prosecution and verification as two pods: findings, then reproduce-or-kill.
- C8. Merge queue, preview, acceptance, release, as the spec's pods describe them.
- C9. Distill, calibration, and the static observability page.

## Non-goals

- N1. Windows outside WSL2. Private repos. Cross-project sharing.
- N2. Money changing hands. Any paid service.
- N3. Agent-to-agent messaging; conclusions pass through artifacts.
- N4. A scheduler, coordinator, or any machine that must stay on.
- N5. Enforcing anything through `AGENTS.md`.

## Done means

- D1. A fresh clone plus `/factory:join` is the whole onboarding.
- D2. A monthly drill ticket trips the kill switch, retires a test node with an open
  claim, forces a merge-queue ejection, and lets a preview expire, and every one recovers
  without a human inside one janitor interval.
- D3. A human can go a week without opening the repo and still be pulled in within an hour
  of being needed, by exactly two kinds of immediate message.
- D4. The ready queue is non-empty and `merge-forecast` certifies width > 1.

## License

**MIT**, proposed. The spec says the license is chosen here before the first merge; the
repo owner confirms it (or changes it) before the first push. Node owners DCO-sign agent
commits (`Signed-off-by:`), and every agent commit carries `Assisted-by:` so the project's
AI-contribution disclosure is machine-checkable.

## Who

Owner: @musicofhel. Bus factor rule: two org owners minimum before the queue opens
(spec, "Bus factor"); the second owner is named in `CODEOWNERS` when they join.
