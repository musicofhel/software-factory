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
| `cpu`, `ram_gb` | from the wizard probe |
| `slots` | `floor(free RAM GB / 2) - 1`, capped at 8; fleet concurrency |
| `heavy_gates` | true if the full suite finished inside the ticket timeout in the dry run |
| `adapters` | name → pinned version; drift from the installed CLI refuses claims |
| `quota_tier` | self-declared, picks ticket weight only; nobody audits it |
| `quota_cap` | fraction of the owner's window, default 0.4; governor pauses at the cap |
| `quiet_hours` | `{ "tz": "...", "start": "HH:MM", "end": "HH:MM" }`, default the owner's working day |
| `accounts` | count only (for cux rotation); never names |
| `factory_version` | the `factory/VERSION` the node last pulled |
| `last_seen` | ISO 8601 UTC; written on every heartbeat |
| `status` | `joining`, `active`, `paused` (node); `stale` after 24 h silent, `retired` after 7 days (janitor) |
