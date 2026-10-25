# TB3 — Budget governor (ticket T8)

Session 6, 2026-10-25 (local). Box: WSL2, Linux 6.18.33.2-microsoft-standard-WSL2, jq-1.7, GNU date,
cux 0.4.1 in `~/.local/bin` (TB0), claude-code 2.1.280. The work landed as `406da29` (`Ticket: T8`). This
file, the ledger line and the handoff land in the next commit. Nothing was pushed (I1). No prep existed for
this row (`specs/factory-step2-v1/prep/` is absent).

Files (all inside T8's scope): `factory/bin/governor.sh`, `factory/bin/lib/governor.sh`,
`factory/bin/quota-gate.sh`, `factory/policy/budget.json` (three new `governor` keys), `tests/fakes/cux`,
`tests/test_governor.sh`.

## 1. DoD and T8 acceptance → evidence

| item | where | proof |
|---|---|---|
| `governor.sh --json` composes, in the spec's order, version_check → heartbeat → kill_switch_check → quiet_hours_check → quota_check | `factory/bin/governor.sh` (header lists each step and its reason codes) | case `order`: behind+HALT+quiet+quota → `refuse version_behind`; HALT+quiet+quota → `sleep halted`; quiet+quota → `sleep quiet_hours` and cux is never called |
| one JSON line `{action, reason, sleep_seconds}`; exit 0 claim/sleep, 2 refuse, 1 operational | `verdict()` in governor.sh | case `claim` (exactly one stdout line, exact bytes), every case compares the whole line |
| AC1 one case per reason: version behind → refuse; HALT → sleep haltSleepMinutes; quiet → until they end; all at cap → until earliest reset; else claim | | cases `version-behind`, `halted` (1800 s from budget.json), `quiet-hours`, `quota-exhausted`, `claim`; plus `version-unknown`, `halt-unknown`, `heartbeat-refusals` for the reasons this row added |
| AC2 midnight wrap 22:00–07:00 on both sides | `gov_quiet` in lib/governor.sh | case `midnight-wrap`: 23:30 → 27000, 03:00 → 14400, 22:00 → 32400, 06:59:59 → 1, 00:00 → 25200; 07:00, 21:59, 12:00 → claim; start == end → no window |
| AC3 DST in America/New_York, spring forward and fall back | `gov_quiet` (offset taken at the end instant, not now) | case `dst` (§2): 8 h ordinary, 9 h fall back, 7 h spring forward, end inside the skipped hour, both passes of the repeated hour |
| AC4 malformed or empty cux payload → sleep, never claim | `gov_quota` + governor step 5 | case `cux-malformed`: 11 malformed payloads, an empty cache file, cux missing → `sleep quota_unknown 600`, each checked for no account key |
| AC5 heartbeat hourly at most | governor step 2 + `gov_heartbeat` | case `heartbeat-hourly`: 59 min → nodes tip unchanged; 61 min without `--apply` → nothing written; with `--apply` → one fast-forward commit, `last_seen` = now, joining → active, every other field kept, `Node:` trailer, the manifest follows; +30 min → skipped; +60 min → due again. Cases `heartbeat-cas` (a racer moves nodes once → retried and won on attempt 2, racer's commit kept; three losses → warning, nothing forced, next run due) and `heartbeat-refusals` |
| AC6 the fake cux tested against the real v0.4.1 shape | `tests/fakes/cux` | case `fake-cux`: the bytes recorded from the real binary (§3) round-trip byte for byte, also from a reordered copy; `{}` for no/empty cache; exit 1 + `cux: usage: parse cache:` for garbage; `status --json` refused (exit 2); the recorded payload through the reader at caps 0.6/0.5/0.4 |
| AC7 quota-gate.sh: 0 under; non-zero at/above cap or malformed | `factory/bin/quota-gate.sh` | case `quota-gate`: under → 0; all at cap → 2; malformed, `{}`, stale → 1; `--cap` and manifest `quota_cap`; run under `env -i PATH HOME` with an absolute argv[0] (fleet's `--pre-strike-argv` shape) → 0; live §4 with the real cux |
| AC8 shellcheck -S warning clean | | `make lint` exit 0 (§5) |
| tests use a fake cux and `FACTORY_NOW` | | every case; `FACTORY_NOW` is epoch or ISO-8601 (case `claim` proves both, and an offset) |
| I8: no prompt/file text or account key leaves | stderr and stdout carry counts only; `cux usage refresh` output (it lists the e-mails) is dropped | `noleak` checks in `claim`, `quota-exhausted`, `cux-malformed`, `quota-gate`; the fake's refresh prints the e-mails, so the check can fail |

## 2. Offline gates (at `406da29`)

```
$ bash tests/test_governor.sh
  PASS claim   PASS version-behind   PASS version-unknown   PASS halted   PASS halt-unknown   PASS quiet-hours
  PASS quota-exhausted   PASS order   PASS midnight-wrap   PASS dst   PASS cux-malformed   PASS heartbeat-hourly
  PASS heartbeat-cas   PASS heartbeat-refusals   PASS fake-cux   PASS quota-gate
exit=0        (140 checks)

  case dst
    ok   an ordinary night, 23:00 EDT to 07:00 EDT = 8 h: sleep 28800 s
    ok   fall back, 23:00 EDT to 07:00 EST = 9 h: sleep 32400 s
    ok   spring forward, 23:00 EST to 07:00 EDT = 7 h: sleep 25200 s
    ok   spring forward, end 02:30 does not exist: until 03:00 EDT: sleep 1800 s
    ok   fall back, 01:10 EDT: until the first 01:30: sleep 1200 s
    ok   fall back, 01:10 EST (the hour again): until the second 01:30: sleep 1200 s
    ok   fall back, 01:45 EDT is outside 01:00-01:30: claim
    ok   spring forward, 03:00 EDT is past the end: claim
  PASS dst

$ make test        # 12 files
PASS tests/test_claim.sh  PASS tests/test_governor.sh  PASS tests/test_halt_rules.sh  PASS tests/test_halt.sh
PASS tests/test_janitor.sh  PASS tests/test_join.sh  PASS tests/test_layout.sh  PASS tests/test_mirror.sh
PASS tests/test_policy.sh  PASS tests/test_post_merge.sh  PASS tests/test_summon.sh  PASS tests/test_version_check.sh
exit=0
```

Mutation check (each applied to a copy of `factory/bin/lib/governor.sh`, then restored; `cmp` confirmed):

| mutation | cases that went red |
|---|---|
| no midnight wrap (`start > end` → never inside) | midnight-wrap, dst |
| end instant computed with today's offset (ignore the DST change) | dst |
| at the cap is not capped (`>=` → `>`) | quota-exhausted, quota-gate |
| `{}` reads as under | cux-malformed, quota-gate |
| no `cux usage refresh` | claim, quota-gate |

## 3. The cux surface coded against (I7)

`cux status --json` does not exist at v0.4.1 (TB0 §8, ADR-0005). Re-read at tag v0.4.1 (read-only):

```
$ gh api 'repos/inulute/cux/contents/internal/usage/usage.go?ref=v0.4.1' --jq .content | base64 -d   # 714 lines
$ gh api 'repos/inulute/cux/contents/cmd/cux/main.go?ref=v0.4.1' --jq .content | base64 -d          # cmdUsageShow, cmdUsageRefresh
$ gh api 'repos/inulute/cux/contents/internal/paths/paths.go?ref=v0.4.1' --jq .content | base64 -d  # BackupRoot: $XDG_DATA_HOME/cux on Linux
```

What the source says, and what the code does with it:

- `cux usage show` = `LoadCache()` then `json.MarshalIndent(cache, "", "  ")`. The cache is
  `map[email]AccountUsage`. A missing or zero-byte file is `{}` (exit 0); unparseable is
  `cux: usage: parse cache: …` and exit 1.
- `AccountUsage.MarshalJSON` is flat: `polled_at` (always), `five_hour` and `seven_day` when set,
  `token_expired` only when true, `retry_after` and `failures` when set, and each model window under its own
  key (`seven_day_<family>`, from the API's `limits[]` `weekly_scoped` entries). `Window` is
  `{utilization 0.0–100.0, resets_at?}` in that field order; a nil `resets_at` is omitted.
- `UnmarshalJSON` keeps an unknown key only when it decodes as a window with a non-zero utilization or a
  reset. So unknown non-window keys (`extra_usage`) never reach the cache, and the reader ignores them too.
- `Settled(now)` drops a window whose `resets_at` is not after now. The reader does the same.
- `StaleAfter = 30 min`. The reader treats an older reading as unknown (`governor.quotaStaleMinutes` = 30).
- `cux usage refresh` repolls every account, prints the `cux list` table (account e-mails) on stdout and
  warnings on stderr, and exits 1 only when nothing was polled and something failed. The governor and the
  gate send both streams to /dev/null and go on with the cached reading.

The real binary, fed a synthetic cache under a temporary `XDG_DATA_HOME` (the input carried the API's
`limits[]`, a null window, a zero window with no reset, an unknown key and an offset `resets_at`):

```
$ XDG_DATA_HOME=$d/xdg HOME=$d cux usage show; echo "exit=$?"
{
  "a@example.invalid": {
    "five_hour": {
      "utilization": 42,
      "resets_at": "2026-10-25T07:00:00.5Z"
    },
    "polled_at": "2026-10-25T03:50:00.123456789Z",
    "seven_day": {
      "utilization": 12.5,
      "resets_at": "2026-10-30T00:00:00Z"
    },
    "seven_day_fable": {
      "utilization": 55,
      "resets_at": "2026-10-29T00:00:00Z"
    }
  },
  "b@example.invalid": {
    "failures": 2,
    "five_hour": {
      "utilization": 100
    },
    "polled_at": "2026-10-25T03:00:00Z",
    "retry_after": "2026-10-25T04:00:00Z",
    "token_expired": true
  }
}
exit=0
$ (cache = one newline) cux usage show  → cux: usage: parse cache: unexpected end of JSON input   exit=1
$ (cache = "garbage")   cux usage show  → cux: usage: parse cache: invalid character 'g' looking for beginning of value   exit=1
```

These bytes are the `RECORDED` constant in `tests/test_governor.sh` (case `fake-cux`).

### Decisions on the quota reading (lib/governor.sh header)

1. **Which windows count: all of them.** five_hour, seven_day and every model window count. cux ranks seats on
   all of them: usage.go #52 says a seat capped on a model window is picked, refused and swapped back. An
   account is at the cap when any window that has not reset is ≥ `quota_cap × 100`.
2. **When the node frees.** An account frees when the last of its capped windows resets. The node frees at
   the earliest account. The spec's "earliest reset" is read per account, because one account's capped
   five_hour resetting does not help while its capped seven_day is still capped. An account with no known
   time (expired token, or a capped window without `resets_at`) counts as `unknownStateSleepMinutes` from
   now, so it is re-read rather than slept on for days.
3. **Fail closed.** These count as unknown and never claim: a payload that is not an object; `{}` (cux
   manages no account: on this box today, §4); an account with no `polled_at`, a stale reading, a malformed
   five_hour/seven_day or `resets_at`, or no window at all. One account under the cap is enough to claim,
   even beside a malformed account.
4. **Fractions of a second round up** on `resets_at` (`07:00:00.5Z` → 07:00:01), so the loop never wakes
   before a reset.
5. **The cap compare** is on the percentage rounded to 1e-6, so 40 at 0.4 is at the cap (`0.4 * 100` is not
   exactly 40 in floating point). Case `quota-exhausted` covers 40 → at cap and 39.99 → under.

## 4. Live, real cux 0.4.1 on this box (no account added; read-only fetch of the real origin)

```
$ factory/bin/quota-gate.sh --json   # real cux, no account on this box
{"state":"unknown","why":"no-accounts","accounts":0,"under":0,"at_cap":0,"unknown":0,"sleep_seconds":600}
quota-gate: unknown: 0 account(s), 0 under the cap, 0 at it, 0 unknown (no-accounts)
exit=1
$ XDG_DATA_HOME=<tmp> factory/bin/quota-gate.sh --json --no-refresh   # real cux, synthetic cache: one account at 55 %
{"state":"exhausted","why":"all-at-cap","accounts":1,"under":0,"at_cap":1,"unknown":0,"sleep_seconds":7199}
quota-gate: exhausted: 1 account(s), 0 under the cap, 1 at it, 0 unknown (all-at-cap)
exit=2
$ XDG_DATA_HOME=<tmp> factory/bin/quota-gate.sh --json --no-refresh --cap 0.6
{"state":"under","why":"headroom","accounts":1,"under":1,"at_cap":0,"unknown":0,"sleep_seconds":0}
quota-gate: under: 1 account(s), 1 under the cap, 0 at it, 0 unknown (headroom)
exit=0
$ factory/bin/governor.sh --json --manifest <tmp>/m.json   # dry run, real origin (read-only fetch), real cux
governor: heartbeat: due (last_seen 2026-10-25T00:00:00Z); would push nodes/dev-box.json (dry run, no --apply)
governor: quota: 0 account(s): 0 under, 0 at cap, 0 unknown (no-accounts)
governor: quota reading unusable (no-accounts): fail closed
{"action":"sleep","reason":"quota_unknown","sleep_seconds":600}
exit=0
```

The manifest was `factory/nodes/example.json` with handle dev-box, owner musicofhel, last_seen
00:00Z and an empty quiet window. version_check and kill_switch_check passed against the real origin/main. The
heartbeat was due but not pushed (no `--apply`; I1). Quota: this box's cux manages no account, so `{}` →
fail closed. **This box cannot claim until `cux add` is run for at least one account.** That is a
first-join step; it is in the handoff for TB6.

## 5. Lint

```
$ make lint
exit=0     (shellcheck -S warning over factory/ and tests/ incl. tests/fakes/cux; actionlint)
```

## 6. Decisions and deviations

- **FACTORY_NOW takes ISO-8601 or epoch.** The ticket says ISO-8601; `lib/common.sh` `now_epoch` takes
  epoch only and is outside T8's scope. `gov_now` (lib/governor.sh) takes both. The governor exports the
  epoch value to the scripts it calls.
- **New reason codes** beyond the spec's four: `version_unknown`, `halt_unknown` (a sub-check that exits 1:
  state unknown → sleep `unknownStateSleepMinutes`, not exit 1, so the run loop has one branch per action);
  `adapter_pins` (version-check exit 2 for a drift, unpinned or unlisted adapter, apart from `version_behind`);
  `node_unregistered`, `node_retired`, `handle_taken` (heartbeat refusals); `quota_exhausted`,
  `quota_unknown`; `ok` for claim. Closed set: `ok version_behind adapter_pins version_unknown
  node_unregistered node_retired handle_taken halted halt_unknown quiet_hours quota_exhausted quota_unknown`.
- **The governor is a writer** because of the heartbeat. Per I3 it is dry-run by default; `--apply` pushes.
  The run loop (T9) must call `governor.sh --json --apply`.
- **The heartbeat CAS code is a copy, not a shared lib.** join.sh's nodes commit loop is outside T8's scope
  (`join.sh`, `lib/common.sh` are not in T8's globs). `gov_heartbeat` is the same compare-and-swap (fetch
  tip, `commit-tree` on it, plain push, `ls-remote` to tell a race from a refusal, 3 attempts). It validates
  through `join.sh --validate`, which calls the script and leaves it unedited. A later desk ticket can fold
  both into one lib.
- **Heartbeat failure is a warning, not a gate.** A push that loses three races or cannot reach the remote
  leaves the manifest's `last_seen` unmoved, so the next run is due again. An unreachable remote fails
  halt-check anyway, so the node sleeps (`halt_unknown`). A missing, retired or foreign `nodes/<h>.json` is a
  refuse: the node must re-join.
- **Status on heartbeat:** joining | stale → active; active and paused are kept; retired → refuse. The
  janitor only ever moves nodes toward stale and retired (janitor.sh `plan_nodes`). Nothing moved a node to
  active before this row.
- **`sleep_seconds` is the whole wait** (for example 9 h of quiet hours, 6 days to a seven_day reset). The
  run loop must nap in pieces no longer than `nodeHeartbeatMinutes` and ask again. Otherwise a long sleep
  would let the node go stale (janitor: 24 h).
- **The quota check refreshes by default** (`cux usage refresh`, then `show`). `--no-refresh` exists on both
  scripts.
- **An unknown tz is exit 1, not a sleep.** jq reads an unknown `TZ` as UTC without a word, so the zone is
  checked against `${TZDIR:-/usr/share/zoneinfo}` first. A manifest with a bad zone is an operational
  error.
