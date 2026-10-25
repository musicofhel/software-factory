# ADR-0003: Chassis (the one open decision)

- Status: accepted (ticket T5; it was proposed until 2026-10-24)
- Date: 2026-10-24
- Deciders: @musicofhel. The bootstrap loop `specs/factory-step1-v1` drafted it under ticket T5,
  and it lands with the first push.

## Context

The spec assumes ADLC `fleet` composed by `ru` as the chassis (ticket → sandboxed run → PR)
([SPEC-v0.2, "The one open decision: the chassis"][spec-open]). The supersession pass surfaced
two single-machine chassis with wider adapter support: Untrivial-ai/agent-orchestrator (mature,
20+ harnesses, Go daemon) and Bernstein (deterministic gating, 31 adapters, one month old). It
also kept three earlier candidates: norma, Fabro and Symphony's `SPEC.md`. Ticket T5 names five
to read: four alternatives (Symphony, norma, Fabro, agent-orchestrator) plus the fleet default.
Bernstein is not one of the five and was not read for this ADR.

The run loop asks five questions of whatever runs inside `case reason:`
([SPEC-v0.2, "Run loop"][spec-runloop]):

1. **Multi-machine over a public repo.** Can independent peer nodes each pick up work from one
   public repo?
2. **Adapter count.** How many coding-agent harnesses can it drive?
3. **Deterministic gating.** Do code-defined gates decide merge, ordering and retries, or does a
   model?
4. **`--json` reason codes.** Is there a closed, machine-readable outcome set the loop can key on?
5. **Sandbox story.** What contains the agent and the repo's commands?

What was read, all pinned to the commit fetched on 2026-10-24 (read-only `gh api` fetches):

| candidate | repo @ commit | files read |
|---|---|---|
| fleet (default) | voodootikigod/adlc @ `455524c` | `packages/fleet/README.md` |
| Symphony | openai/symphony @ `be10a1b` | `SPEC.md`, `README.md` |
| norma | normahq/norma @ `de11cc4` | `docs/pdca-agent.md`, `README.md` |
| Fabro | fabro-sh/fabro @ `1906d7c` | `.fabro/workflows/implement-issue/workflow.fabro`, `.fabro/workflows/implement-plan/workflow.fabro`, `test/docs/tutorials/plan-implement/plan-implement.fabro`, `docs/public/{core-concepts/agents,execution/outcomes,administration/sandboxing}.mdx`, `README.md` |
| agent-orchestrator | OrchestratorInc/agent-orchestrator @ `2782e4d` (`Untrivial-ai/agent-orchestrator` now redirects here) | `README.md` (the adapter list), `docs/architecture.md`, `docs/cli/README.md` |

### fleet's position (the baseline the lines below compare against)

- **Multi-machine:** none. fleet works on one host. It dispatches to local worktrees
  ([README L3-8][fleet-what]), merges into `fleet/run-<runId>`, opens at most one PR and never
  pushes ([README L37-38][fleet-integ]). Multi-machine comes from this spec's claim protocol and
  nodes, not from fleet.
- **Adapters:** 6: `claude-code`, `codex`, `agy`, `opencode`, `pi`, `cursor`
  ([README "Worker harnesses", L97-103][fleet-adapters]). The operator picks one locally, and a
  value in repo config is ignored ([L119-124][fleet-oplocal]).
- **Gating:** deterministic. "No LLM call decides ordering, retries, or merges"
  ([L7-8][fleet-what]). It runs deterministic pre-merge gates ([L28-33][fleet-gates]) and a
  blocking cross-model prosecution that fails closed ([L34-36][fleet-gates]).
- **Reason codes:** `fleet run --json` prints one document. `reason` comes from a closed set:
  `quota-paused`, `lock-held`, `wall-clock`, `strikes-exhausted`, `ticket-blocked`, `flail`,
  `review-unavailable`, `mirror-fetch-failed`. Run-level codes sit outside that set
  ([README "The `--json` result and the reason set", L252-273][fleet-reasons]).
- **Sandbox:** an OS sandbox on the repo-command plane, fail closed ([L19-21][fleet-what],
  [L76-81, L92-93][fleet-prereq]). Model-plane writes are bounded but its reads are not
  ([L159-163][fleet-residual]). On Linux only `bwrap` is accepted; this box has none, so a live
  run refuses here (`specs/factory-step1-v1/records/TB0.md` §2).

## Decision

**The chassis is ADLC `fleet` (`@adlc/cli` 1.12.0, pinned), composed by the run loop exactly as
SPEC-v0.2 "Run loop" writes it.** One line per candidate versus fleet, on the five questions:

- **fleet** (baseline): multi-machine SAME (none; the claim protocol supplies it)
  ([L37-38][fleet-integ]) · adapters SAME (6) ([L97-103][fleet-adapters]) · gating SAME
  (deterministic) ([L7-8][fleet-what]) · reason codes SAME (closed set) ([L252-273][fleet-reasons])
  · sandbox SAME (OS sandbox, fail closed) ([L19-21][fleet-what]).
- **Symphony**: multi-machine DIFFERENT (an optional SSH extension keeps one central orchestrator
  as "the single source of truth for polling, claims, retries" ([Appendix A.1][sym-ssh]), and a
  "distributed job scheduler" is a non-goal ([§2.2][sym-goals])) · adapters DIFFERENT (1: a
  Codex app-server-compatible process) ([§3.3][sym-deps], [§10.1][sym-launch]) · gating DIFFERENT
  (no gates: on any error the attempt fails and is retried ([§10.7][sym-runner]), and ticket logic
  "lives in the workflow prompt" ([§2.2][sym-goals])) · reason codes DIFFERENT (only RECOMMENDED
  error categories ([§10.6][sym-errors]), and "the orchestrator only relies on success vs.
  failure" ([§11.4][sym-tracker-err])) · sandbox DIFFERENT (not mandated; only the workspace path
  is contained) ([§1][sym-problem], [§15.2][sym-fs]).
- **norma**: multi-machine SAME (none: run history is stored "same-machine" in SQLite and
  `.norma/runs`) ([Target Simplified Sequence, L63][norma-state]) · adapters DIFFERENT (5 ACP
  aliases plus `generic_acp`) ([Provider Routing Policy, L233-237][norma-acp]) · gating DIFFERENT
  (a Check *agent's* `pass`/`fail` verdict decides completion ([Control Semantics,
  L21-25][norma-control], [Verdict rules, L168-171][norma-verdict]), and Norma then squash-merges
  into the base branch ([L118-120][norma-merge])) · reason codes DIFFERENT (run status
  `passed`/`failed`/`stopped` plus a free-text `stop_reason`, with no quota or wall-clock outcome)
  ([L25][norma-control], [Stop Conditions, L220-229][norma-stop]) · sandbox DIFFERENT (only a git
  worktree per run; no OS sandbox) ([Workspaces and Artifacts, L196-202][norma-ws]).
- **Fabro**: multi-machine DIFFERENT (one Fabro server queues runs, on a laptop or a host, with
  execution in cloud sandboxes) ([README L41-42][fabro-scale], [L149-152][fabro-host]) · adapters
  DIFFERENT (its own agent loop over LLM provider APIs, plus any ACP stdio agent through
  `backend="acp"`) ([agents.mdx "Backends", L19-36][fabro-backends]) · gating SAME (a
  deterministic DOT graph: a command node succeeds only on exit 0 ([outcomes.mdx L27][fabro-cmd]),
  and `goal_gate=true` fails the run unless the gate succeeded ([L116][fabro-goalgate]). The
  implement-plan example gates on a `verify` script with `goal_gate=true` and loops to `fixup`
  ([workflow.fabro L15, L27-29][fabro-verify]). Caveat: an agent node may set its own outcome
  ([outcomes.mdx L28][fabro-cmd])) · reason codes DIFFERENT (four node outcomes: `succeeded`,
  `failed`, `partially_succeeded`, `skipped`, with no quota, wall-clock or flail reason)
  ([outcomes.mdx "The four outcomes", L8-15][fabro-outcomes]) · sandbox DIFFERENT (`local` with
  no isolation, `docker`, or a `daytona` cloud VM, with network control only on Daytona)
  ([sandboxing.mdx L8, L29][fabro-sandbox]).
- **agent-orchestrator**: multi-machine DIFFERENT (a local desktop app plus a daemon
  ([README L33-35][ao-local]); remote hosts pair to one desktop over LAN or a Cloudflare tunnel
  ([docs/cli/README.md L36-44][ao-remote])) · adapters DIFFERENT (36 harnesses in the "Supported
  agents" table) ([README L130-195][ao-agents]) · gating DIFFERENT (an LLM project orchestrator
  plans and delegates ([README L67-71][ao-orch]); the Kanban reflects CI and review facts but
  gates nothing ([L77-82][ao-kanban])) · reason codes DIFFERENT (`ao status --json` reports daemon
  state, not task outcomes) ([docs/cli/README.md L31][ao-status]) · sandbox DIFFERENT (a worktree
  per session ([architecture.md L1249][ao-iso]); its ACP path is "instruction policy rather than an
  enforced read-only sandbox" ([L457][ao-acp])).

Why fleet:

1. **Only fleet answers question 4.** The run loop's `case reason:` is written against fleet's
   closed set (`quota-paused | wall-clock`, `strikes-exhausted | flail`, `review-unavailable`).
   Symphony's orchestrator acts only on success versus failure. norma's `stop_reason` is free
   text. Fabro's four outcomes cannot tell a quota pause from a failure. agent-orchestrator
   exposes no per-task outcome. Any of the four would need a translation layer that guesses.
2. **Only fleet fails closed on an OS sandbox.** No candidate offers an OS sandbox that refuses
   to run when it is missing. Symphony does not mandate one. norma and agent-orchestrator isolate
   with worktrees only. Fabro's default is `local` with no isolation, and its network control is
   on a hosted cloud VM. The trust rules (a stranger's PR must not wreck a teammate's box) need
   the fail-closed one.
3. **Only fleet and Fabro gate deterministically**, and only fleet adds a blocking cross-model
   prosecution. Fabro's gates are as deterministic as each graph's author makes them, because an
   agent node can set its own outcome.
4. **No candidate does multi-machine over a public repo, fleet included.** That property comes
   from this spec's git-ref claim protocol and node manifests in every case, so it decides
   nothing between them. The two that reach across machines (Symphony over SSH,
   agent-orchestrator through paired remote hosts) do it with one central owner of claims. That
   contradicts the peer-node claim protocol.
5. **fleet loses on adapter count**: 6 versus agent-orchestrator's 36. Today it does not matter:
   claude-code is the only adapter on the one node (SPEC factory-step1-v1 §0), and fleet's
   operator-local `--adapter-command`/`--adapter-args` override is a one-line fix for a CLI change
   ([README L170-180][fleet-override]). Revisit when a node's only harness is outside fleet's six.

**The state machines, trust rules, manifest and claim protocol are unchanged by this decision.**
The ticket, node and claim state machines, the trust rules, the node manifest and the git-ref claim
protocol stay exactly as SPEC-v0.2 writes them. The decision changes only the run loop's inner
command, which stays `fleet run --tickets <id> --concurrency 1 --no-pr --no-complete …`.

## Consequences

- Build order 2 (the run loop) codes `case reason:` against fleet's closed set in
  [README L261-273][fleet-reasons]. Run-level reasons (`preflight`, `dispatch-refused`, …) take
  the "anything else" branch.
- A node needs `bwrap` on Linux (or `sandbox-exec` on macOS). `unshare` alone is rejected
  (`specs/factory-step1-v1/records/TB0.md` §2). The join wizard must probe for it and refuse to
  register a node without it.
- The adapter shortlist is fleet's six. A harness outside it needs either a fleet adapter upstream
  or an ADR that revisits this one. agent-orchestrator is the reference for how wide the field is.
  It is not a drop-in replacement: it is a desktop app whose telemetry includes the GitHub
  username ([README L236-239][ao-telemetry]), and it has no outcome codes.
- Fabro's DOT graphs are worth borrowing as a *notation* for a ticket's verify loop
  (`verify → fixup → verify`). That would be a separate ADR. It does not change the chassis.
- Re-open this ADR if fleet's reason set changes shape in a pinned upgrade, if fleet stops failing
  closed on the sandbox, or if a candidate ships both a closed outcome enum and a fail-closed OS
  sandbox.

[spec-open]: https://github.com/musicofhel/software-factory/blob/20371e24457cd37dcf0492fff309bf62c3b054cc/docs/spec/SPEC-v0.2.txt#L1260-L1269
[spec-runloop]: https://github.com/musicofhel/software-factory/blob/20371e24457cd37dcf0492fff309bf62c3b054cc/docs/spec/SPEC-v0.2.txt#L349-L386
[fleet-what]: https://github.com/voodootikigod/adlc/blob/455524c411ff3699e8e63fb05ced260e2fa5a892/packages/fleet/README.md?plain=1#L3-L21
[fleet-gates]: https://github.com/voodootikigod/adlc/blob/455524c411ff3699e8e63fb05ced260e2fa5a892/packages/fleet/README.md?plain=1#L28-L36
[fleet-integ]: https://github.com/voodootikigod/adlc/blob/455524c411ff3699e8e63fb05ced260e2fa5a892/packages/fleet/README.md?plain=1#L37-L38
[fleet-prereq]: https://github.com/voodootikigod/adlc/blob/455524c411ff3699e8e63fb05ced260e2fa5a892/packages/fleet/README.md?plain=1#L74-L93
[fleet-adapters]: https://github.com/voodootikigod/adlc/blob/455524c411ff3699e8e63fb05ced260e2fa5a892/packages/fleet/README.md?plain=1#L95-L103
[fleet-oplocal]: https://github.com/voodootikigod/adlc/blob/455524c411ff3699e8e63fb05ced260e2fa5a892/packages/fleet/README.md?plain=1#L119-L124
[fleet-residual]: https://github.com/voodootikigod/adlc/blob/455524c411ff3699e8e63fb05ced260e2fa5a892/packages/fleet/README.md?plain=1#L159-L163
[fleet-override]: https://github.com/voodootikigod/adlc/blob/455524c411ff3699e8e63fb05ced260e2fa5a892/packages/fleet/README.md?plain=1#L170-L180
[fleet-reasons]: https://github.com/voodootikigod/adlc/blob/455524c411ff3699e8e63fb05ced260e2fa5a892/packages/fleet/README.md?plain=1#L252-L273
[sym-problem]: https://github.com/openai/symphony/blob/be10a1b79df723d6d7612b5651c8522704dafb2e/SPEC.md?plain=1#L31-L34
[sym-goals]: https://github.com/openai/symphony/blob/be10a1b79df723d6d7612b5651c8522704dafb2e/SPEC.md?plain=1#L60-L69
[sym-deps]: https://github.com/openai/symphony/blob/be10a1b79df723d6d7612b5651c8522704dafb2e/SPEC.md?plain=1#L143-L150
[sym-launch]: https://github.com/openai/symphony/blob/be10a1b79df723d6d7612b5651c8522704dafb2e/SPEC.md?plain=1#L966-L979
[sym-errors]: https://github.com/openai/symphony/blob/be10a1b79df723d6d7612b5651c8522704dafb2e/SPEC.md?plain=1#L1151-L1161
[sym-runner]: https://github.com/openai/symphony/blob/be10a1b79df723d6d7612b5651c8522704dafb2e/SPEC.md?plain=1#L1163-L1177
[sym-tracker-err]: https://github.com/openai/symphony/blob/be10a1b79df723d6d7612b5651c8522704dafb2e/SPEC.md?plain=1#L1299-L1302
[sym-fs]: https://github.com/openai/symphony/blob/be10a1b79df723d6d7612b5651c8522704dafb2e/SPEC.md?plain=1#L1734-L1740
[sym-ssh]: https://github.com/openai/symphony/blob/be10a1b79df723d6d7612b5651c8522704dafb2e/SPEC.md?plain=1#L2252-L2273
[norma-control]: https://github.com/normahq/norma/blob/de11cc49bcf0cf87e758298ed5fceb60135e6f4a/docs/pdca-agent.md?plain=1#L21-L25
[norma-state]: https://github.com/normahq/norma/blob/de11cc49bcf0cf87e758298ed5fceb60135e6f4a/docs/pdca-agent.md?plain=1#L57-L66
[norma-merge]: https://github.com/normahq/norma/blob/de11cc49bcf0cf87e758298ed5fceb60135e6f4a/docs/pdca-agent.md?plain=1#L118-L122
[norma-verdict]: https://github.com/normahq/norma/blob/de11cc49bcf0cf87e758298ed5fceb60135e6f4a/docs/pdca-agent.md?plain=1#L168-L171
[norma-ws]: https://github.com/normahq/norma/blob/de11cc49bcf0cf87e758298ed5fceb60135e6f4a/docs/pdca-agent.md?plain=1#L196-L202
[norma-stop]: https://github.com/normahq/norma/blob/de11cc49bcf0cf87e758298ed5fceb60135e6f4a/docs/pdca-agent.md?plain=1#L220-L229
[norma-acp]: https://github.com/normahq/norma/blob/de11cc49bcf0cf87e758298ed5fceb60135e6f4a/docs/pdca-agent.md?plain=1#L231-L237
[fabro-scale]: https://github.com/fabro-sh/fabro/blob/1906d7c9ea4912103f78f0cff8b8d2feef139643/README.md?plain=1#L40-L42
[fabro-host]: https://github.com/fabro-sh/fabro/blob/1906d7c9ea4912103f78f0cff8b8d2feef139643/README.md?plain=1#L149-L152
[fabro-backends]: https://github.com/fabro-sh/fabro/blob/1906d7c9ea4912103f78f0cff8b8d2feef139643/docs/public/core-concepts/agents.mdx?plain=1#L19-L36
[fabro-outcomes]: https://github.com/fabro-sh/fabro/blob/1906d7c9ea4912103f78f0cff8b8d2feef139643/docs/public/execution/outcomes.mdx?plain=1#L8-L15
[fabro-cmd]: https://github.com/fabro-sh/fabro/blob/1906d7c9ea4912103f78f0cff8b8d2feef139643/docs/public/execution/outcomes.mdx?plain=1#L21-L32
[fabro-goalgate]: https://github.com/fabro-sh/fabro/blob/1906d7c9ea4912103f78f0cff8b8d2feef139643/docs/public/execution/outcomes.mdx?plain=1#L109-L118
[fabro-verify]: https://github.com/fabro-sh/fabro/blob/1906d7c9ea4912103f78f0cff8b8d2feef139643/.fabro/workflows/implement-plan/workflow.fabro#L15-L29
[fabro-sandbox]: https://github.com/fabro-sh/fabro/blob/1906d7c9ea4912103f78f0cff8b8d2feef139643/docs/public/administration/sandboxing.mdx?plain=1#L6-L29
[ao-local]: https://github.com/OrchestratorInc/agent-orchestrator/blob/2782e4d7f6914457daa9696cd8bccd249ec5603e/README.md?plain=1#L31-L35
[ao-orch]: https://github.com/OrchestratorInc/agent-orchestrator/blob/2782e4d7f6914457daa9696cd8bccd249ec5603e/README.md?plain=1#L65-L71
[ao-kanban]: https://github.com/OrchestratorInc/agent-orchestrator/blob/2782e4d7f6914457daa9696cd8bccd249ec5603e/README.md?plain=1#L75-L82
[ao-agents]: https://github.com/OrchestratorInc/agent-orchestrator/blob/2782e4d7f6914457daa9696cd8bccd249ec5603e/README.md?plain=1#L130-L195
[ao-telemetry]: https://github.com/OrchestratorInc/agent-orchestrator/blob/2782e4d7f6914457daa9696cd8bccd249ec5603e/README.md?plain=1#L236-L239
[ao-status]: https://github.com/OrchestratorInc/agent-orchestrator/blob/2782e4d7f6914457daa9696cd8bccd249ec5603e/docs/cli/README.md?plain=1#L31
[ao-remote]: https://github.com/OrchestratorInc/agent-orchestrator/blob/2782e4d7f6914457daa9696cd8bccd249ec5603e/docs/cli/README.md?plain=1#L36-L44
[ao-acp]: https://github.com/OrchestratorInc/agent-orchestrator/blob/2782e4d7f6914457daa9696cd8bccd249ec5603e/docs/architecture.md?plain=1#L453-L458
[ao-iso]: https://github.com/OrchestratorInc/agent-orchestrator/blob/2782e4d7f6914457daa9696cd8bccd249ec5603e/docs/architecture.md?plain=1#L1249
