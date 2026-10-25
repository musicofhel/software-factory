# factory-run-calls-v1 rulings (TB0 block)

Aaron submitted the decision page "Two Store Calls" on 2026-10-25 22:31Z
(https://claude.ai/artifact/15DUXFtmV42fdUuYJPDGiK, store doc `rulings/two-store-calls-20261025`).
He picked the preselected recommendation on both and left no notes. The questions are in full in this
spec's HANDOFF (session 1, `### Q1`, `### Q2`) and on the page.

| Q | Call | Ruling | Where it lands |
|---|---|---|---|
| Q1 | Rails freeze main's ticket store (`MANIFEST_KEY_REQUIRED`) | **Unsigned.** T19 is written first (no flag needed), T18 and T17 with `--allow-unsigned`; post-merge.sh learns `--allow-unsigned` for `ticket complete` inside T18's scope. No key, no new secret; a key may replace this later (matches `.adlc/config.json` `securityMode: unsigned-fallback`) | TB0 (writes), TB2 (T18 scope + post-merge.sh) |
| Q2 | vetto cannot start under the real `$HOME` (`~/.aws` symlink) | **Scratch HOME in TB1's live test**, with the render's absolute roots pointing at the real uv tool and python dirs and the clone's `.git`; the records state the real-HOME failure (ADR-0005 T6 item 10) and that it fails closed | TB1 |
