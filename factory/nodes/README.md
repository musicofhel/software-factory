# Node manifests

Manifests live on the `nodes` branch as `nodes/<handle>.json`, one per node, committed by
the node itself (the push is the heartbeat, hourly at most). `main` holds only this schema.
The janitor writes `status`; the node writes everything else.

Schema: `manifest.schema.json` (JSON Schema draft 2020-12). Field notes:

| Field | Notes |
|---|---|
| `handle` | GitHub login of the owner's node; used in branch and lock names |
| `owner` | GitHub login |
| `os` | `linux`, `macos`, `wsl2` |
| `cpu` | from the wizard probe (`nproc`; `sysctl hw.ncpu` on macOS) |
| `ram_gb` | MemTotal in GiB, rounded to an integer (a box sold as "8 GB" reports about 7.6 GiB and rounds to 8, the schema minimum) |
| `slots` | `min(8, floor(free GiB / 2) - 1)`, computed on whole kB of MemAvailable (`ram_free_kb / 2097152 - 1`); fleet concurrency. The wizard refuses below 1 |
| `heavy_gates` | true if `make test` passed inside `budget.json` `weights.light.suiteMinutesMax` (600 s) in the wizard's timed run; false on a timeout, a failure, or `--no-suite` |
| `adapters` | name → pinned version, at least one. Names are the keys of `factory/policy/adapters.json`: `claude-code`, `codex`, `gemini`, `agy`, `jetski`, `opencode`, `pi`, `cursor`, `copilot` (the schema's `propertyNames` enum; a test keeps the two equal). The wizard lists only adapters that are installed, authenticated and pinned there; drift from the installed CLI refuses claims |
| `review` | fleet's trusted reviewer as the wizard installed it: `{ "tool": "adversarial-review", "pin": "2.11.1", "same_family": true }`. `same_family` is true when the node has one usable adapter, so the reviewer runs on the builder's model family (a claude-only box); ruling Q4 accepts that until build-order step 4. Optional in the schema, so manifests written before it still validate; the wizard always writes it |
| `quota_tier` | self-declared, picks ticket weight only; nobody audits it |
| `quota_cap` | fraction of the owner's window, default 0.4; governor pauses at the cap |
| `quiet_hours` | `{ "tz": "...", "start": "HH:MM", "end": "HH:MM" }`, default the owner's working day |
| `accounts` | count only (for cux rotation); never names |
| `factory_version` | the `factory/VERSION` the node last pulled |
| `last_seen` | ISO 8601 UTC; written on every heartbeat |
| `status` | `joining`, `active`, `paused` (node); `stale` after 24 h silent, `retired` after 7 days (janitor). The join wizard writes `joining` |

The join wizard (`factory/bin/join.sh`, `/factory:join`) builds the manifest, checks it with
`join.sh --validate <file>` (the schema interpreted by jq; a keyword the validator does not
implement fails closed), commits it on top of the `nodes` tip and pushes without force.
