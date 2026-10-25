# TB0 — Register and tickets T17–T19 (PARTIAL: blocked on Q1)

Session date 2026-10-25. Box: WSL2, Linux 6.18.33.2-microsoft-standard-WSL2. Measured at `098cc3f`
(= `origin/main` = local `main`, the SPEC commit on top of `139a06b`). Nothing was pushed (I1). Every
GitHub call below is a read (`gh issue view`, `git ls-remote`). `a` = `npx -y @adlc/cli@1.12.0`.
Blocks are `$ <command>`, its output (trimmed where marked) and `exit=<code>`.

**State: the register is re-measured (§1) and T17–T19 are drafted and proven in a scratch clone (§2),
but nothing is written to main's ticket store.** Writing a railed ticket turns main's store into a
frozen trust root. After that, every later ticket write needs `ADLC_MANIFEST_KEY`, which this box does
not have, or `--allow-unsigned`, which leaves a permanent unsigned audit entry. Post-merge's `ticket
complete` is refused the same way. That is a credential and trust-root call, so it goes to Aaron
(HANDOFF Q1). A second register finding bears on TB1's live DoD (HANDOFF Q2).

## 1. The register, re-measured

| key | SPEC §0 said | measured now | block |
|---|---|---|---|
| repo | `origin/main` = `139a06b`; `make test` 15 files PASS, `make lint` 0 | `origin/main` = local = `098cc3f` (the SPEC commit on top of `139a06b`); `make test` 15 files PASS (1:56 wall); `make lint` exit 0 | §1.1 |
| store | T1–T16 all completed; every ticket has `rails: []` or none | same: T1–T16 `completed: true`; T1–T5 have no `rails` key, T6–T16 `rails: []`; archive empty; manifest 20 entries, none signed | §1.2 |
| tamperguard step | `run.sh` ~L353–376, `on_success`, under `vetto --profile strict --policy factory/policy/build.toml`; stderr to `.factory-run/tamperguard.err`, not kept | same: `on_success` L349; vetto call L356–359; the `case` L368–375; only the JSON is copied to `$LOGBASE.tamperguard.json` (L362), the `.err` is not | §1.3 |
| fix by hand | `~/.cache/tb5/diag3/build-exp.toml` → rc 0, `{"verdict":"ok",…}` | the diag3 render and its JSON still exist, but the smoke scratch they name (`~/.cache/factory-smoke.iCBmLv`) is gone. Re-measured on a fresh clone + linked worktree (§1.4): template → rc 126 `Permission denied`; a render with 4 absolute roots → rc 0 `{"verdict":"ok","score":0,"findings":[]}`. Dropping one root at a time: the uv tool dir and the uv python dir are each load-bearing (rc 126), the clone's `.git` is load-bearing (rc 0, `empty diff, nothing to scan`, no JSON), the bin dir holding the tamperguard symlink is not | §1.4 |
| not measured | whether uv's python dir is readable under the real `$HOME` | **measured, and the answer is that vetto never starts under the real `$HOME` on this box**: `vetto --profile strict --tui none -- true` exits 125 with `mask overlay /home/musicofhel/.aws: … bind /dev/null over /home/musicofhel/.aws: Not a directory`. `~/.aws` is a symlink to `/mnt/c/Users/aaron/.aws/` (a directory), and vetto 0.6.5 masks it as a file. This is ADR-0005 amendment T6 item 10, already known, and join warns about it (`join.sh` L215). Under a scratch HOME, an absolute `allow_read` root for the real `~/.local/share/uv/python` works (§1.4). → HANDOFF Q2 (TB1's live line says "with the real `$HOME`") | §1.4 |
| rails | fleet's gate runs `adlc rails-guard --base <start> --ticket <id>`; exits 1 on no rails; T-smoke declares `factory/policy/**` | same: `@adlc/fleet/lib/live-deps.mjs` L595; `@adlc/rails-guard/lib/rails.mjs` `resolveRailGlobs` L16, error at L25; `tests/live/test_smoke_live.sh` L102 | §1.5 |
| fleet | `@adlc/cli` 1.12.0 newest; #1266 and #1272 open | same: `@adlc/cli` and `@adlc/fleet` 1.12.0 (published 2026-10-10, nothing newer); #1266 OPEN, 0 comments; #1272 OPEN, 0 comments. Upstream `main` moved from `455524c` (follow-ups TB0) to `b43800f` (recorded only; re-pinning is not this spec's) | §1.6 |

**No fleet past 1.12.0 has shipped**, so nothing changes for the pin.

### 1.1 Repo

```
$ git fetch -q origin && git rev-parse origin/main HEAD; git status -sb | head -1
098cc3fd5648cbe2cbcd912f29c18e89191ac22b
098cc3fd5648cbe2cbcd912f29c18e89191ac22b
## main...origin/main
$ time make test          # (every file's line)
PASS tests/test_bwrap_shim.sh
PASS tests/test_claim.sh
PASS tests/test_governor.sh
PASS tests/test_halt_rules.sh
PASS tests/test_halt.sh
PASS tests/test_janitor.sh
PASS tests/test_join.sh
PASS tests/test_layout.sh
PASS tests/test_mirror.sh
PASS tests/test_policy.sh
PASS tests/test_post_merge.sh
PASS tests/test_revoke.sh
PASS tests/test_run.sh
PASS tests/test_summon.sh
PASS tests/test_version_check.sh
make test  92.56s user 28.58s system 104% cpu 1:56.28 total
exit=0
$ make lint
exit=0
```

`make live` was not run in this session: the register has no `make live` line and the row stopped
before its gates (it changes no code).

### 1.2 Store

```
$ for f in .adlc/tickets/*.json; do jq -r '[.id, (.completed // false), ((.rails // "none")|tostring)] | @tsv' $f; done | sort -V
T1 true none   … T5 true none
T6 true []     … T16 true []
$ ls .adlc/ticket-archive | wc -l
0
$ jq -c '{seq,gate,ticket,sig:(.sig // .signature // null)}' .adlc/manifest.jsonl | tail -1
{"seq":20,"gate":"ticket-complete","ticket":"T16","sig":null}
$ jq .securityMode .adlc/config.json
"unsigned-fallback"
```

### 1.3 The tamperguard step

```
$ grep -n 'on_success\|tamperguard' factory/bin/run.sh   # (excerpt)
349:on_success() {
356:  (cd "$WT" && vetto --profile strict --policy "$FACTORY_ROOT/factory/policy/build.toml" --tui none -- \
357:     bash -c 'tamperguard --range "$1" --json >"$2" 2>"$3"; echo "$?" >"$4"' tamperguard "$BASE..$tip" \
358:     .factory-run/tamperguard.json .factory-run/tamperguard.err .factory-run/tamperguard.rc) \
362:  command cp -f "$WT/.factory-run/tamperguard.json" "$LOGBASE.tamperguard.json" 2>/dev/null || true
374:    *) REASON=tamperguard-error; outcome released; finish_release 1 0 1; return ;;
$ grep -n 'allow_read\|allow_write\|^mode' factory/policy/build.toml
30:allow_read = ["$HOME/.factory/cache"]
```

### 1.4 The fix by hand, and the real `$HOME`

The tool on this box is a user-level uv tool, not a FACTORY_HOME one (there is no `~/.factory`):

```
$ readlink -f ~/.local/bin/tamperguard; head -1 "$(readlink -f ~/.local/bin/tamperguard)"
/home/musicofhel/.local/share/uv/tools/tamperguard/bin/tamperguard
#!/home/musicofhel/.local/share/uv/tools/tamperguard/bin/python
$ ls -l ~/.local/share/uv/tools/tamperguard/bin/python; readlink -f ~/.local/share/uv/tools/tamperguard/bin/python
… python -> /home/musicofhel/.local/share/uv/python/cpython-3.14-linux-x86_64-gnu/bin/python3.14
/home/musicofhel/.local/share/uv/python/cpython-3.14.3-linux-x86_64-gnu/bin/python3.14
```

Note the two hops: the tool's `python` names `cpython-3.14-linux-x86_64-gnu` (itself a symlink), which
resolves to `cpython-3.14.3-linux-x86_64-gnu`. A root at the resolved install dir alone would not
cover the intermediate link; `~/.local/share/uv/python` covers both. TB1 must measure this, not
assume `readlink -f`'s dir is enough.

The real HOME:

```
$ cd /tmp && vetto --profile strict --tui none -- true; echo exit=$?   # (tail)
vetto: error: Sandbox process spawn failure: Process spawning failed: sandbox setup failed: child exit 125: :mask overlay /home/musicofhel/.aws: mount operation failed: bind /dev/null over /home/musicofhel/.aws: Not a directory (os error 20)
exit=125
$ ls -ld ~/.aws /mnt/c/Users/aaron/.aws/
lrwxrwxrwx … /home/musicofhel/.aws -> /mnt/c/Users/aaron/.aws
drwxrwxrwx … /mnt/c/Users/aaron/.aws/
$ vetto --profile strict --policy factory/policy/build.toml policy explain   # (excerpt)
  read roots (17): /bin … /home/musicofhel/.cargo/bin /home/musicofhel/.factory/cache /home/musicofhel/.local/bin … /usr
  masked secrets (3820): mount-masked
    /home/musicofhel/.ssh/
    /home/musicofhel/.aws            <- no trailing slash: vetto took the symlink for a file
    /home/musicofhel/.gnupg/
```

The re-measure script is `~/.cache/tb0-run/fix.sh` (node-local, not committed). It builds a clone
with two commits and a linked worktree at the tip, then runs run.sh's exact vetto line with
`HOME=$X/home` (a scratch HOME, because of the above) against the template and against a render whose
`allow_read` adds the real `~/.local/bin`, `~/.local/share/uv/tools/tamperguard`,
`~/.local/share/uv/python` and the clone's `.git`:

```
$ bash ~/.cache/tb0-run/fix.sh
[template] vetto=125 rc=126 json= err=tamperguard: line 1: /home/musicofhel/.local/bin/tamperguard: Permission denied
allow_read = ["$HOME/.factory/cache", "/home/musicofhel/.local/bin", "/home/musicofhel/.local/share/uv/tools/tamperguard", "/home/musicofhel/.local/share/uv/python", "/home/musicofhel/.cache/tb0-run/fix/clone/.git"]
[render] vetto=125 rc=0 json={"verdict":"ok","score":0,"findings":[]} err=
[minus-bin] vetto=125 rc=0 json={"verdict":"ok","score":0,"findings":[]} err=
[minus-tamperguard] vetto=125 rc=126 json= err=tamperguard: line 1: /home/musicofhel/.local/bin/tamperguard: Permission denied
[minus-python] vetto=125 rc=126 json= err=tamperguard: /home/musicofhel/.local/bin/tamperguard: /home/musicofhel/.local/share/uv/tools/tamperguard/bin/python: bad interpreter: Permission denied
[minus-.git] vetto=125 rc=0 json= err=tamperguard: empty diff, nothing to scan
```

(vetto's own 125 is ADR-0005 amendment T6 item 1; the verdict is the rc file.) The `minus-.git` line
is the follow-ups' "rc 0, no JSON" case that run.sh correctly refuses as `tamperguard-error`.

### 1.5 Rails

```
$ F=~/.npm/_npx/45e3560a1487d0e5/node_modules/@adlc
$ grep -n "rails-guard', '--base'" $F/fleet/lib/live-deps.mjs
595:        const res = await io.adlcAsync(['rails-guard', '--base', startSha, '--ticket', ticket.id], …
$ grep -n 'resolveRailGlobs\|no rails declared' $F/rails-guard/lib/rails.mjs
16:export function resolveRailGlobs(cliRails, ticket) {
25:    return { globs: [], error: `ticket ${ticket.id} has no rails declared` };
$ grep -n 'rails: \["factory/policy' tests/live/test_smoke_live.sh
102:    duration: 1, scope: ["hello.sh", "tests/test_hello.sh"], rails: ["factory/policy/**"], edges: [], body: $b}' >"$S/t-smoke.json"
```

### 1.6 fleet and the upstream issues (read-only)

```
$ npm view @adlc/cli version; npm view @adlc/fleet version
1.12.0
1.12.0
$ npm view @adlc/cli time --json | jq -r 'to_entries|sort_by(.value)|.[-3:][]|"\(.key) \(.value)"'
1.11.1 2026-09-09T12:35:26.327Z
1.12.0 2026-10-10T03:26:21.041Z
modified 2026-10-10T03:26:21.401Z
$ for i in 1266 1272; do gh issue view $i -R voodootikigod/adlc --json number,state,title,createdAt,updatedAt,comments,closedAt | jq -c '{number,state,title,createdAt,updatedAt,closedAt,comments:(.comments|length)}'; done
{"number":1266,"state":"OPEN","title":"fleet: preflight canary cannot pass on any bubblewrap host (no system root bound, `/bin/sh` missing)","createdAt":"2026-10-25T12:25:19Z","updatedAt":"2026-10-25T12:25:19Z","closedAt":null,"comments":0}
{"number":1272,"state":"OPEN","title":"fleet spends every strike on a ticket rails-guard cannot evaluate","createdAt":"2026-10-25T20:27:04Z","updatedAt":"2026-10-25T20:27:04Z","closedAt":null,"comments":0}
$ git ls-remote https://github.com/voodootikigod/adlc.git refs/heads/main
b43800fb7d9543ef556dcb334fce2d4e09005289	refs/heads/main
```

## 2. Tickets T17–T19: drafted, proven in a scratch clone, NOT written to main's store

### 2.1 Why the write stopped

`adlc ticket create --help` (1.12.0): "FROZEN TRUST ROOT. Once any ticket declares a rail, the ticket
store is … frozen: every --write against it is a deliberate, AUDITED override that appends one signed
`ticket-mutation` entry to the gate-manifest … Signing it needs ADLC_MANIFEST_KEY. Without the key the
write REFUSES … Pass --allow-unsigned to record an unsigned entry on purpose. … Completing, archiving or
discarding the last railed ticket does not thaw it." There is no batch write (`adlc ticket --help`), so
only the first railed ticket can be written without the key.

Measured in a scratch clone of `098cc3f` (probe tickets T99 then T98, both railed):

```
$ a ticket create --input t99.json --write --json          # first railed ticket
… {"applied": true, …}  exit=0                             # no key needed, no manifest entry
$ a ticket create --input t98.json --write --json          # second
{"ok":false,"kind":"policy","code":"MANIFEST_KEY_REQUIRED","message":"this ticket store is a frozen trust root (a ticket declares rails), so mutating it is an audited override — and ADLC_MANIFEST_KEY is not set, … Refusing before the write: nothing has changed. …"}
exit=2
$ a ticket create --input t98.json --write --allow-unsigned --json
warning: --allow-unsigned with no ADLC_MANIFEST_KEY — this mutation of a frozen trust root will be recorded UNSIGNED. … The manifest is append-only, so this entry is permanent.
… exit=0; manifest seq 21 {"gate":"ticket-mutation","ticket":"T98","data":{…,"bypass":true}}
$ a ticket complete T99 --write --authorize --json >/dev/null 2>&1; echo exit=$?   # what post-merge.sh L173 runs
exit=2                                                     # MANIFEST_KEY_REQUIRED
$ # a rail-free ticket T90 in the same frozen store (scratch of §2.3):
$ a ticket complete T90 --write --authorize --json >/dev/null 2>c.err; echo exit=$?
exit=2                                                     # MANIFEST_KEY_REQUIRED, the same message
```

`ADLC_MANIFEST_KEY` is not set in this session, there is no `.env.local` in the main checkout, and no
`ADLC_MANIFEST_KEY` secret is referenced by any workflow (`.github/workflows/post-merge.yml` reads only
`FACTORY_APP_KEY`). `factory/bin/post-merge.sh` passes no `--allow-unsigned`. So once main's store
holds a railed ticket:

- every desk write (T17's and T18's creates, later edge or scope widenings, every new ticket) needs the
  key or `--allow-unsigned`;
- post-merge (CI or by hand) fails to complete any ticket, railed or not, with `failed adlc ticket
  complete exit 2`, until it has the key or passes `--allow-unsigned`. Today post-merge.sh's code
  cannot do the latter, and changing it is a ticket of its own.

step-2 TB0 §5 avoided rails for exactly this reason ("this row has no key"). Ruling Q2 and this SPEC
put a rail on every ticket, but neither the ruling page nor the SPEC names the freeze. This loop
decides neither a signing key nor permanent unsigned audit entries for Aaron. → HANDOFF Q1.

### 2.2 The drafts

`specs/factory-run-calls-v1/records/tickets/T17.json`, `T18.json`, `T19.json` are the exact input
documents. Each body opens with the ADR-0002 header block, every acceptance criterion ends in
`Verify: <command>`, and each declares `rails: ["factory/policy/**"]`.

| id | header | title | scope | edges |
|---|---|---|---|---|
| T17 | light / 1 / C5 | Run the loop's tamperguard step under a per-claim rendered copy of build.toml (ruling Q1) | `factory/bin/run.sh`, `factory/bin/lib/run.sh`, `factory/bin/lib/policy-render.sh`, `docs/adr/0005-run-loop-cli-reality.md`, `tests/test_run.sh`, `tests/fakes/vetto`, `tests/fakes/tamperguard`, `tests/live/test_render_live.sh` | T18, T19 |
| T18 | light / 0 / C2 | Make factory/policy/** every ticket's default rail and refuse an open ticket without rails (ruling Q2) | `factory/bin/mirror.sh`, `factory/bin/ticket-check.sh`, `factory/RULES.md`, `docs/adr/0002-adlc-sharded-ticket-store.md`, `Makefile`, `tests/test_mirror.sh`, `tests/test_ticket_check.sh`, `tests/fakes/adlc`, `tests/fakes/mirror/**` | T19 |
| T19 | heavy / 2 / C5 | Run the toy ticket to scope-check-not-built on the dev box, and close out factory-run-calls-v1 | `tests/live/test_smoke*.sh`, `tests/fixtures/make-repo.sh`, `README.md` | — |

No scope names `factory/policy/**` (I15). Charters as in step 2: the run loop is C5 (T12, T16), and the
mirror's ready gate is the claim protocol, C2 (T14). The edge T17→T18 is not in the SPEC. The first
scratch forecast vetoed the pair (below), so it is in T17's draft, in row order (TB1 = T17, TB2 = T18).

### 2.3 The write sequence, proven in a scratch clone (`~/.cache/tb0-run/scratch`, a clone of `098cc3f`)

The order is the reverse dependency order, because an edge to an unwritten ticket fails validation.
T19 is the first railed ticket, so it needs no key. T18 and T17 used `--allow-unsigned` here, in the
scratch only, to prove the drafts. First pass (T17 without the T18 edge):

```
$ a merge-forecast --json | jq -c '(.pairs[] | select(.verdict != "PARALLEL") | {pair, signal, score, verdict}), {gateFailures, waves}'
{"pair":"T17–T18","signal":"co-change","score":0.5,"verdict":"SEQUENCE"}
{"gateFailures":["1 high-risk pair(s) would run concurrently: T17–T18 (score 0.5, co-change)"],"waves":[["T17","T18"],["T19"]]}
exit=2
```

Second pass, on a fresh clone, with the edge in T17's draft:

```
$ for t in T19 T18 T17; do a ticket create --input $t.json --json; a ticket create --input $t.json --write [--allow-unsigned for T18,T17] --json; done
T19 dry=0 write=0  {"applied":true,"ticketHash":"00625c0fd8e5"}
T18 dry=0 write=0 --allow-unsigned {"applied":true,"ticketHash":"4d796411d1b6"} warning: --allow-unsigned with no ADLC_MANIFEST_KEY — …
T17 dry=0 write=0 --allow-unsigned {"applied":true,"ticketHash":"21374cb6a8ef"} warning: --allow-unsigned with no ADLC_MANIFEST_KEY — …
$ a ticket doctor
All checks passed.   exit=0
$ a coldstart --all --offline --json | jq -c '.ok, (.results[] | select(.id|IN("T17","T18","T19")) | {id, pass, gaps})'
true
{"id":"T17","pass":true,"gaps":[]}
{"id":"T18","pass":true,"gaps":[]}
{"id":"T19","pass":true,"gaps":[]}
$ a merge-forecast --json | jq -c '(.pairs[]? | select(.verdict != "PARALLEL")), {gateFailures, waves}'
{"gateFailures":[],"waves":[["T17"],["T18"],["T19"]]}
exit=0
$ for t in T17 T18 T19; do a ticket show $t --json | jq -r '[.ticket.id, .ticketHash[0:12], (.ticket.edges // [] | map(.to) | join(",")), (.ticket.rails|join(",")), (.ticket.body | split("\n")[0:3] | join(" "))] | @tsv'; done
T17	21374cb6a8ef	T18,T19	factory/policy/**	weight: light tier: 1 charter: C5
T18	4d796411d1b6	T19	factory/policy/**	weight: light tier: 0 charter: C2
T19	00625c0fd8e5		factory/policy/**	weight: heavy tier: 2 charter: C5
```

So once Q1 is ruled, the write on main is this same loop with the ruled flag or key: two `ticket-mutation`
manifest entries (T18 and T17) and three new ticket files. No edge update is needed afterwards.

## 3. Gotchas for the next rows

1. **The frozen trust root (§2.1).** Every row after TB0 that writes the store, and post-merge, inherits
   Q1's answer. TB2's mirror check reads the store and does not write it.
2. **vetto never starts under this box's real `$HOME`** (§1.4; ADR-0005 amendment T6 item 10). TB1's
   live test must either run with a scratch HOME, as the smoke does, or wait for `~/.aws` to change (Q2).
3. **Two-hop uv interpreter** (§1.4): `tools/tamperguard/bin/python` → `uv/python/cpython-3.14-…` (a
   symlink) → `cpython-3.14.3-…`. Landlock checks every path the exec walks. The render's interpreter
   root must cover the link dir as well as the resolved dir. On this box `~/.local/share/uv/python` covers
   both; prove it in TB1 by dropping roots one at a time, as §1.4 does.
4. On this box tamperguard is a user-level uv tool (`~/.local/bin` → `~/.local/share/uv/tools`), and
   there is no `~/.factory`. A joined node's is under FACTORY_HOME (`$FH/bin`, `$FH/uv`). The render must
   derive the roots from the resolved tool path, not assume either layout.
5. The bin dir holding the tamperguard symlink is not load-bearing (§1.4 `minus-bin` passes). The
   SPEC's "FACTORY_HOME's bin" root is harmless but is not the fix; the uv tool dir is.

## 4. Result

PARTIAL. Every register line is re-measured (§1). The "not measured" line is now measured, and its answer
is a blocker for TB1's live line as worded (Q2). No fleet past 1.12.0 has shipped. T17–T19 are drafted and
proven in a scratch store: doctor ok, coldstart gaps empty, merge-forecast exit 0 (§2.3). They are not
written to main's store pending Q1. `make test` 15 PASS, `make lint` 0. No commit `Ticket: scaffold`
with store changes yet.
