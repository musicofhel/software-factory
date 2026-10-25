# TB2 — The default rail and the check (ticket T18; ruling Q2, ruling Q1 for post-merge)

Session 4 of the loop, 2026-10-25. No prep exists for this spec (`prep/` is absent). Commit
`Ticket: T18` (hash in LEDGER). Tools: `@adlc/cli` 1.12.0 (npx), jq, shellcheck through `make lint`.
Scratch: `~/.cache/tb2-run/` (node-local, disposable).

## 1. The real CLI, measured first (I7)

These measurements are the contract for the fake adlc's new behaviour. They were taken in scratch
clones of main at `74e2fad` (`frozen`: the store holds T17–T19, railed) and at `c13c121` (`thawed`:
T1–T16 only, no rails).

```
$ cd frozen; a ticket complete T19 --write --authorize --json; echo exit=$?
stdout: the plan ({"version":1,"operation":"complete",…,"dryRun":false})
stderr: {"ok":false,"kind":"policy","code":"MANIFEST_KEY_REQUIRED","message":"this ticket store is a frozen trust root (a ticket declares rails), so mutating it is an audited override — and ADLC_MANIFEST_KEY is not set, … Refusing before the write: nothing has changed. … To record an UNSIGNED audit entry on purpose, pass --allow-unsigned."}
exit=2
$ a ticket complete T19 --write --authorize --allow-unsigned --json; echo exit=$?
stdout: the plan, then {"applied":true,"storeHash":"6003a28c…","ticketHash":"34354464…"}
stderr: warning: --allow-unsigned with no ADLC_MANIFEST_KEY — this mutation of a frozen trust root will be recorded UNSIGNED. …
exit=0; manifest 22 → 23 lines; the new one: {"gate":"ticket-complete","ticket":"T19","data":{…,"op":"complete","bypass":true}}
$ cd thawed; a ticket create --input t90.json --write --json      # a rail-free probe ticket, store not frozen
exit=0
$ a ticket complete T90 --write --authorize --allow-unsigned --json; echo exit=$?
exit=0; stderr empty (no warning); manifest +1: {"gate":"ticket-complete","ticket":"T90","bypass":null}
$ cd frozen; a ticket show T18 --json | jq -c '{rails: .ticket.rails}'; a ticket show T3 --json | jq -c '{rails: .ticket.rails, has: (.ticket | has("rails"))}'
{"rails":["factory/policy/**"]}
{"rails":null,"has":false}
$ a ticket list --json | jq -c '.[0] | keys'
["id","ticketHash","title"]                                        # no rails, no completed: a reader needs `ticket show`
```

So:
- **post-merge can always pass `--allow-unsigned`.** A store that is not frozen accepts it silently,
  and a frozen one needs it.
- the refusal leaves the store and manifest untouched. The flagged write records exactly one
  `ticket-complete` entry with `data.bypass: true`, not a separate `ticket-mutation` entry.
- `rails` reaches a reader only through `ticket show`.

The scratch clones were never pushed. Main's store is unchanged, and T19 is still open there.

## 2. What was built

| file | what |
|---|---|
| `factory/RULES.md` | new section "Every ticket declares a rail (the desk's ticket convention)": at least `factory/policy/**`, beside the ADR-0002 header block. It names the two checks, says completed tickets are never relabeled, and covers the frozen store and `--allow-unsigned` (Q1) |
| `docs/adr/0002-adlc-sharded-ticket-store.md` | decision 3 (the default rail; old 3 is now 4) and "Amendment T18 (2026-10-25): the default rail" |
| `factory/bin/mirror.sh` | carries `rails` from `ticket show`. New ready condition `rails`: `rails_reasons($t)` yields `rails: none declared` unless `rails` holds a non-blank string. It sits between the header and the record reasons. The completed branch is untouched, so a completed ticket is only ever closed, never relabeled. The header doc and `usage` range are updated |
| `factory/bin/ticket-check.sh` (new) | **the check behind `make tickets`** (no desk check existed before: `make tickets` was `adlc ticket list` alone and `make doctor` is `adlc ticket doctor`, so this is a new script). It reads list then show, prints one JSON line per ticket `{ticket, completed, rails, result: ok\|refused\|completed, reasons}`, and exits 2 on an open ticket without rails. It exits 1 on any failed read (no verdict), and 0 otherwise. The rail test is the same as mirror's |
| `Makefile` | `tickets:` runs `ticket list`, then `./factory/bin/ticket-check.sh` |
| `factory/bin/post-merge.sh` | `adlc ticket complete <id> --write --authorize --allow-unsigned --json`. The header doc gives the reason (Q1, `securityMode: unsigned-fallback`). The `usage` range now includes the exit-code lines |
| `tests/fakes/adlc` | documents that `ticket show` carries every fixture field, rails included. A store is frozen when any ticket (completed included) has a non-empty `rails`. In a frozen store `complete --write` without `--allow-unsigned` prints the plan, then exits 2 with `MANIFEST_KEY_REQUIRED` on stderr and changes nothing. With the flag it prints the warning and the entry gains `bypass: true`. An unfrozen store takes the flag silently (§1) |
| `tests/test_mirror.sh` | `ticket()` gives every fixture the default rail. New case `rails-required`. `fake-semantics` checks that rails come through `ticket show`, the frozen refusal, and the flagged write |
| `tests/test_post_merge.sh` | `completes` and `range-since-marker` expect `--allow-unsigned`, plus "an unrailed store takes the flag silently". New case `railed-store` |
| `tests/test_ticket_check.sh` (new) | cases `passes-store-as-it-stands`, `refuses-open-without-rails`, `read-failures`, `make-tickets` |

The diff stays inside T18's 11 scope globs, plus this records file and the LEDGER. `factory/policy/**`
is untouched (I15). The store is untouched: T1–T16 keep `rails: []` or none.

**Decision: the check needs a declared rail, not `factory/policy/**` itself.** The DoD says the check
"refuses a ticket whose `rails` is empty or missing". rails-guard fails only on that
(`resolveRailGlobs`: `globs.length === 0`), and ralon-lock protects `factory/policy/**` for every ticket
whatever it declares. So a ticket that declares only `docs/**` passes both checks (pinned by the T5
fixture in the mirror and check tests). The default rail is the desk's convention and is written down in
RULES.md and ADR-0002. A blank-only list (`["", "  "]`) counts as none. rails-guard would accept it and
then match nothing useful.

## 3. Offline proof (`make test`), and the red proofs

| T18 criterion | proof |
|---|---|
| 1. `rails: []` → `needs-desk`, reason `rails: none declared` | `test_mirror.sh` `rails-required`: T2 (`[]`), T3 (no key) and T4 (blanks) get labels `needs-desk,tier:1,w:light` and reasons exactly `["rails: none declared"]`. The Issue body shows `Gate: needs-desk` / `- rails: none declared` |
| 2. with the rail it can be `ready` | same case: T1 is ready (default rail), and T5 (`docs/**`) is ready. The desk then adds the rail to T2: `[ready, [], +ready, -needs-desk]`, exactly one write. Every older case now runs with the default rail and still passes |
| 3. a completed ticket without rails is untouched | same case: T6 (completed, no key, Issue closed) has no line and its Issue JSON is byte-identical before and after. T7 (completed, `[]`, Issue still open with `ready`) is `close`, add `[]`, remove `["ready"]`, never `needs-desk`. T8 (completed, no Issue) gets none created. The rerun gives T6–T8 no line |
| 4. the check fails on an open ticket without rails and passes on the store as it stands | `test_ticket_check.sh`: main's store shape (T1–T5 no key, T6–T16 `[]`, all completed; T17–T19 railed) → exit 0, 16 `completed` + 3 `ok`. T2/T3/T4 → exit 2 `refused`, and stderr names them. Read failures → exit 1 with no line. Live: `make tickets` on main's real store → exit 0 (§4) |
| 5. post-merge completes in a railed store; the fake refuses without the flag | `test_post_merge.sh` `railed-store`: the fake refuses `--write --authorize` alone (exit 2, `MANIFEST_KEY_REQUIRED`, state byte-identical). A wrapper that strips `--allow-unsigned` makes post-merge exit 1, with T1/T2 `failed` and `adlc ticket complete exit 2: …MANIFEST_KEY_REQUIRED` and nothing landed. post-merge as built exits 0, completes T1/T2 with the flag on both calls, records manifest `bypass: true` for each, then lands and pushes |
| 6. the convention is written down | `grep -n "factory/policy/\*\*" factory/RULES.md docs/adr/0002-adlc-sharded-ticket-store.md` → RULES.md L33, L36; ADR-0002 L35, L50, L53 |
| 7. shellcheck clean | `make lint` exit 0 |

**Red proofs.** A scratch worktree at `74e2fad` held the new tests and the new fake on the old code
(old `mirror.sh`, `post-merge.sh` and `Makefile`; no `ticket-check.sh`). They failed as expected:
- `rails-required` (T2/T3/T4 `ready`, reasons `[]`);
- `completes` and `range-since-marker` (argv without `--allow-unsigned`);
- `railed-store` (`[false,false]` flags, nothing completed);
- all 4 ticket-check cases.

The worktree was removed.

```
$ make test
PASS tests/test_bwrap_shim.sh … PASS tests/test_ticket_check.sh, PASS tests/test_version_check.sh
16 files PASS (15 before + the new test_ticket_check.sh); 2:15 wall
exit=0
$ make lint
exit=0
```

## 4. `make tickets` on main's real store (network: npx only; reads only)

```
$ make tickets >out 2>err; echo exit=$?
exit=0
$ grep '"result"' out | jq -sc 'group_by(.result) | map([.[0].result, length])'
[["completed",16],["ok",3]]
{"ticket":"T17","completed":false,"rails":["factory/policy/**"],"result":"ok","reasons":[]}
{"ticket":"T18","completed":false,"rails":["factory/policy/**"],"result":"ok","reasons":[]}
{"ticket":"T19","completed":false,"rails":["factory/policy/**"],"result":"ok","reasons":[]}
```

## 5. What this unblocks

TB0 §2.4 and HANDOFF gotcha 3: post-merge could not complete T17 (or anything else) in main's frozen
store until it passed `--allow-unsigned`. It passes it now. post-merge runs only on a GitHub-hosted
runner, and nothing is pushed (I1), so no completion was run here. The first post-merge run after
these commits reach main's origin will complete T17 and T18 together, each as an unsigned
`ticket-complete` entry.

## 6. Result

Done. The convention is written in RULES.md and ADR-0002. mirror holds an open rail-free ticket at
`needs-desk` (`rails: none declared`). `make tickets` (`factory/bin/ticket-check.sh`) exits 2 on it and
0 on main's store. post-merge passes `--allow-unsigned`, and the fake refuses without it, as adlc
1.12.0 does. `make test` 16 PASS, `make lint` 0, the red proofs fail on the old code, and rails-guard
on the commit passes (LEDGER).
