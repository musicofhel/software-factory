# Distributed Software Factory

A hobby team pools its own laptops and model subscriptions to build one project from a
shared ticket backlog. Agents do the building; humans hold two gates (spec approval and
behavioral acceptance). Everything in between is machine-gated.

This repo is both the factory and its first project: every change under `factory/` goes
through the full lifecycle before the queue opens to anything else.

The design is [`docs/spec/SPEC-v0.2.txt`](docs/spec/SPEC-v0.2.txt) (the PDF is beside it).
Read it once; nothing below contradicts it.

## Non-negotiables (from the spec)

- **Cheap.** One public GitHub repo, free Actions minutes, self-hosted runners on members'
  machines for heavy jobs. No paid service, no shared API key.
- **Pull, not push.** Idle nodes claim work. No scheduler, no coordinator, no machine that
  must stay on. Every cross-node service is a GitHub Action or a git branch.
- **Control flow is code, judgment is models.** No model decides a claim, a gate verdict, a
  merge order, or a release.
- **Two human gates only:** spec approval (P1) and behavioral acceptance (P6).
- **Etiquette by mechanism.** Branch protection, claim TTLs, scoped tokens, a kill switch,
  quota caps. Nothing that matters lives only in `AGENTS.md`.
- **Your account stays yours.** Quota cap defaults to 40 % of your window and the node
  sleeps through your working day.

## Joining (once the join wizard lands, build order step 2)

```sh
git clone https://github.com/musicofhel/software-factory
cd software-factory
claude            # then: /factory:join
```

The wizard probes your box, installs the pinned toolchain in safe mode, registers a
repo-scoped token and runner, and commits your node manifest to the `nodes` branch. It
writes nowhere outside the clone and `~/.factory/`. Until it lands, `factory/skills/join/`
documents every step it will take.

## Layout

| Path | What |
|---|---|
| `PROJECT.md` | Charter: what, scope, non-goals, done-means, license |
| `AGENTS.md` | Agent guidance. Untrusted by design; nothing enforced lives here |
| `CONTRIBUTING.md` | How a human joins; DCO; the `Assisted-by:` trailer |
| `CODEOWNERS` | `factory/`, `.adlc/`, `.github/`, `.claude/` need two humans |
| `factory/VERSION` | Nodes refuse to claim while behind this |
| `factory/RULES.md` | House rules, printed by the wizard |
| `factory/HALT` | Kill switch. **Absent on `main` = running.** Present = every loop sleeps |
| `factory/skills/` | `join`, `run`, `release` (a Claude Code plugin: `/factory:join` …) |
| `factory/bin/` | The deterministic code: claim, heartbeat, release, janitor, mirror, digest |
| `factory/nodes/` | Manifest schema only. Manifests live on the `nodes` branch |
| `factory/policy/` | Sandbox profiles, prosecution depth, quarantine list, branch rules as code |
| `factory/ledger/` | Verified prosecution findings (`findings.jsonl`), input to distill |
| `factory/fixtures/` | Synthetic data for heavy gates and previews |
| `.adlc/` | Ticket source of truth (ADLC sharded store; see ADR-0002) |
| `.github/workflows/` | Gates, janitor, mirror, digest, summoner, distill |
| `docs/adr/` | Decision records |
| `specs/` | The build-loop specs that built the factory (the record, not the product) |

## Branches

`main` is the project. `nodes` is the live node registry (one JSON per node, heartbeat-
committed hourly, never merged to `main`). `ticket/<id>/<handle>` are build branches.
`flaky-history` holds test history. `refs/locks/*` are claim locks, not branches. Nothing
else is long-lived.

## Build order and status

| # | Step | Status |
|---|---|---|
| 1 | Clock + janitor, claim protocol, kill switch | **in progress** (`specs/factory-step1-v1`) |
| 2 | Join wizard and run loop (vetto, Ralon, dcg, cux) | queued |
| 3 | CI gates and merge queue with the `Depends-on:` hold | queued |
| 4 | Rail author charter, prosecution CLI, verifier wrapper, summoner, digest | queued |
| 5 | Preview, behavior diff, release | queued |
| 6 | Distill, calibration, observability page | queued |
| 7 | Open the queue to the real project | queued |

Nothing is safe without TTLs and a stop, so step 1 comes first.

## Testing

```sh
make test     # every tests/*.sh, offline, no keys
make lint     # shellcheck + actionlint if installed
```
