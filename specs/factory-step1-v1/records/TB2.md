# TB2 — Kill switch (ticket T2)

Session date 2026-10-24. Box: WSL2. Base `bea579f`. Nothing was pushed. No write reached the real
GitHub: every `gh` in the tests is `tests/fakes/gh` and every `curl` is `tests/fakes/curl`. The
only real-GitHub calls were the three read-only `gh api` GETs in §5. A Discord webhook was never
contacted. One smoke run did go to the real `curl`, before the fake was `chmod +x`. Its target was
`https://discord.test/x`, a reserved TLD that never resolves, so it failed with `curl: (6) Could
not resolve host` and sent nothing. No prep existed for this row (`specs/factory-step1-v1/prep/`
is absent).

## 1. What was built

| file | role |
|---|---|
| `factory/bin/halt-check.sh` | `git fetch <remote> +refs/heads/main:refs/remotes/<remote>/main`, then `git ls-tree <sha> factory/HALT`. Exit 0 absent (stdout empty); exit 3 present (stdout = `budget .governor.haltSleepMinutes`, 30); exit 1 when the fetch fails (unknown ≠ absent: do not claim). `--json`, `--remote`, `--branch`. |
| `factory/bin/apply-branch-protection.sh` | Reads GET protection + GET each repository ruleset. Plans one call per write: PUT protection, POST a new ruleset, PUT a drifted one by id. Prints each as a runnable `gh api … --input - <<< '<json>'` line. Noops are listed and never sent. Dry run by default; `--apply` sends. Compares only the fields the policy names. Unmanaged rulesets are reported and never deleted. Refuses (exit 2, before any call) a policy field that is not a GitHub REST field. Prints the policy's `unexpressed` rules on every run. |
| `factory/bin/summon.sh` | `--kind halt\|needs-approval\|needs-acceptance`, anything else exit 2. Sends one Discord message naming one human, the ticket id, the decision needed and a link. Fields come from flags, else from `$GITHUB_EVENT_PATH` (see its header for the order). `allowed_mentions.parse = []`. Dry run by default; `--apply` POSTs to `$DISCORD_WEBHOOK`, and the URL is redacted from errors. A push whose commit lacks `factory/HALT` (a lift) is exit 0 with no message. |
| `factory/policy/branch-protection.json` | Rewritten to real REST bodies: `protection` = the PUT body; `rulesets` = `main-merge-queue` (the merge queue is a ruleset rule, `merge_queue`; classic protection has no such field); `unexpressed` = the HALT asymmetry → ADR-0004. The fake `path_filter` ruleset is gone. |
| `.github/workflows/summoner.yml` | The label `factory:halt` now maps to `--kind halt` (it used to pass the raw label, which summon refuses). Passes `--apply`. Adds `SUMMONER_TO: ${{ vars.SUMMONER_TO }}` (optional; unset falls back to CODEOWNERS). |
| `tests/fakes/gh` | + `--input FILE\|-`, `?query` stripped, `branches/<b>/protection` GET/PUT (GitHub's GET shape: wrapped booleans, `checks[]`, server defaults; 404 "Branch not protected" vs "Branch not found"; 422 without the four required keys), `rulesets` list (summaries only) / GET / POST / PUT (422 on duplicate name or unknown rule type), backed by `$FAKE_GH_SETTINGS`. |
| `tests/fakes/curl` | New. Logs `{url, method, headers, body, argv}` per call to `$FAKE_CURL_LOG`. `@-`/`@file`/literal bodies. `FAKE_CURL_FAIL` → exit 22 with an error naming the full URL (the worst case, so callers' redaction is tested). Unknown flags exit 2. |
| `tests/fakes/lib.sh` | `fakegh_setup` also makes an empty settings store and curl log, and unsets the summoner env. |
| `tests/test_halt.sh` | T2 criteria 1 and 5: `absent`, `present`, `working-tree-ignored`, `fetch-fails-closed`, `layout-refuses-halt` (runs test_layout.sh on a copy of the tracked tree, with and without `factory/HALT`). |
| `tests/test_halt_rules.sh` | T2 criterion 2: `dry-run-prints-calls` (dry run sends 0 writes; the printed lines run by hand produce the policy; `--apply` sends exactly the plan; a second `--apply` sends 0), `drift-is-corrected`, `unmanaged-left-alone`, `refuses-made-up-fields` (the scaffold's `path_filter` included), `read-errors-fail`, `fake-gh-settings`. |
| `tests/test_summon.sh` | T2 criteria 3 and 4: `halt` (push, lift, label), `needs-approval`, `needs-acceptance`, `refuses-other-kinds`, `never-more-than-one-human`, `dry-run-and-failures`, `workflow-triggers` (grep assertions, documented in the case), `fake-curl-semantics`. |
| `docs/adr/0004-halt-two-person-rule.md` | Proposed. GitHub cannot express "0 to add, 2 to remove". Records the interim and options A–D for Aaron. |
| `CODEOWNERS` | The comment on `factory/HALT` no longer claims a deletion-keyed rule exists. The owner line is unchanged. |

T2's scope was widened through the store before those last two files were written. The ADR is
required by SPEC I7, and the CODEOWNERS comment was false:
```
$ npx -y @adlc/cli@1.12.0 ticket show T2 --json > env.json
$ jq '.ticket | .scope += ["CODEOWNERS", "docs/adr/0004-halt-two-person-rule.md"]' env.json > T2.json
$ npx -y @adlc/cli@1.12.0 ticket update T2 --input T2.json --expect "$(jq -r .ticketHash env.json)" --authorize --write
{ "applied": true, "storeHash": "d933be06…", "ticketHash": "2e6b4400…" }
```
`--authorize` (widening scope is sensitive) made ADLC write its audit log `.adlc/manifest.jsonl`
(seq 1). `.gitignore` deliberately un-ignores that file, so it is committed with this row.

Changed paths (`git status --porcelain --untracked-files=all`), all inside T2's scope after the
update, plus the store's own two files:
```
 M .adlc/tickets/t2--0f617ba9….json
 M .github/workflows/summoner.yml
 M CODEOWNERS
 M factory/bin/apply-branch-protection.sh
 M factory/bin/halt-check.sh
 M factory/bin/summon.sh
 M factory/policy/branch-protection.json
 M tests/fakes/gh
 M tests/fakes/lib.sh
?? .adlc/manifest.jsonl
?? docs/adr/0004-halt-two-person-rule.md
?? tests/fakes/curl
?? tests/test_halt.sh
?? tests/test_halt_rules.sh
?? tests/test_summon.sh
```

## 2. Gates (run concurrently, final tree)

`$ make test` (case lines; 211 `ok` checks in all, 126 of them in the three new files: halt 21,
halt_rules 43, summon 62):
```
test_claim
  PASS fake-gh-semantics
  PASS skips-locked
  PASS cas-422-moves-on
  PASS one-comment
  PASS heartbeat-and-stale
  PASS never-delete-foreign-lock
PASS tests/test_claim.sh
test_halt_rules
  PASS fake-gh-settings
  PASS dry-run-prints-calls
  PASS drift-is-corrected
  PASS unmanaged-left-alone
  PASS refuses-made-up-fields
  PASS read-errors-fail
PASS tests/test_halt_rules.sh
test_halt
  PASS absent
  PASS present
  PASS working-tree-ignored
  PASS fetch-fails-closed
  PASS layout-refuses-halt
PASS tests/test_halt.sh
PASS tests/test_layout.sh
test_summon
  PASS fake-curl-semantics
  PASS halt
  PASS needs-approval
  PASS needs-acceptance
  PASS refuses-other-kinds
  PASS never-more-than-one-human
  PASS dry-run-and-failures
  PASS workflow-triggers
PASS tests/test_summon.sh
exit=0
```
`$ make lint` → no output, `exit=0`. This is shellcheck `-S warning` over every `factory/**/*.sh`
and `tests/**` file, including `tests/fakes/curl`, then actionlint over the workflows (via `uvx`).
The first lint run failed on SC2100 (`PROG=apply-branch-protection` reads as arithmetic) and on
SC2034 (`ERR` is only read inside `eval` strings). Both were fixed: the value is now quoted, and
the disable carries a reason.

`$ npx -y @adlc/cli@1.12.0 ticket doctor` → `All checks passed.` `exit=0`

`$ npx -y @adlc/cli@1.12.0 coldstart T2 --offline --json`
```
{"ok":true,"results":[{"id":"T2","pass":true,"gaps":[],"cached":false,"offline":true}]}
exit=0
```
Stubs: `grep -l 'not built' factory/bin/*.sh` no longer lists halt-check, apply-branch-protection
or summon. These still list, as expected: attest-verify, commit-check, digest, janitor, mirror,
post-merge, rails-proof, scope-check, skills-scan, version-check.

## 3. The tests can fail (mutation check)

Each mutation was applied with `perl -0pi`, then only the relevant test file was run, then the
original was restored. 26 of 26 were caught, after two fixes described below the table.

| mutation | caught by |
|---|---|
| halt-check reads the working tree (`ls factory/HALT`) | present, working-tree-ignored, fetch-fails-closed |
| halt-check skips the fetch | present, working-tree-ignored, fetch-fails-closed |
| halt-check: a failed fetch exits 0 | fetch-fails-closed |
| halt-check exits 0 when present | present, working-tree-ignored, fetch-fails-closed |
| halt-check prints a fixed 60 | present, working-tree-ignored |
| abp: dry run writes | dry-run-prints-calls |
| abp: noops sent anyway | dry-run-prints-calls |
| abp: drift never detected | drift-is-corrected |
| abp: no validation | refuses-made-up-fields |
| abp: any read error = unprotected | read-errors-fail |
| abp: ruleset always POSTed | dry-run-prints-calls, drift-is-corrected |
| abp: write failure exits 0 | read-errors-fail |
| summon: any kind accepted | refuses-other-kinds |
| summon: posts twice | halt, needs-approval, needs-acceptance, dry-run-and-failures |
| summon: a lift still summons | halt |
| summon: `allowed_mentions` lets @everyone through | halt, needs-approval |
| summon: dry run posts | dry-run-and-failures |
| summon: ticket id dropped from the message | halt, needs-approval, needs-acceptance |
| summon: webhook URL left in the error | dry-run-and-failures |
| summon: multi-handle `--to` accepted | never-more-than-one-human |
| summoner.yml: `paths` filter removed | workflow-triggers |
| summoner.yml: `factory:halt` label not mapped to `halt` | workflow-triggers |
| summoner.yml: no `--apply` | workflow-triggers |
| summoner.yml: a `schedule:` trigger added | workflow-triggers |
| fake gh: PUT protection never stored | fake-gh-settings, dry-run-prints-calls, drift-is-corrected, read-errors-fail |
| fake curl: drops the body | fake-curl-semantics, halt, needs-approval, needs-acceptance |

The two fixes:
- The "webhook URL left in the error" mutation first SURVIVED, because the fake's error did not
  name the URL. The fake now names the full URL in its failure message. A later re-run seemed to
  survive again, but that mutation was broken: perl had interpolated `$err` as empty. Once the
  `$` was escaped, the mutation was caught.
- The first version of "a failed fetch exits 0" made `die` unconditional, which also broke the
  `absent` case. Redone exactly (`die "cannot fetch …"` → `exit 0`), it is caught by
  fetch-fails-closed alone.

## 4. Decisions inside the row

1. **The HALT asymmetry is not expressible on GitHub → ADR-0004 (proposed), not a silent drop.**
   The policy lists it under `unexpressed`, and every run prints it. The validator refuses
   made-up fields, so the scaffold's `path_filter` cannot come back. Interim rule: one
   code-owner approval to add and one to remove. Options A–D are for Aaron (HANDOFF Q-list,
   collected in TB5).
2. **Policy restructured into real request bodies** (`protection`, `rulesets`, `unexpressed`).
   The merge queue moved from a made-up `merge_queue` field on classic protection into the
   `main-merge-queue` ruleset (`merge_queue` rule). The policy named three parameters:
   `MERGE`, `max_entries_to_build: 1`, and `max_entries_to_merge: 1` (consistent with building
   one entry). The other four are GitHub's UI defaults: `min_entries_to_merge 1`,
   `min_entries_to_merge_wait_minutes 5`, `ALLGREEN`, `check_response_timeout_minutes 60`.
3. **Idempotence = projection.** Only the fields the policy names are compared, after mapping
   GET protection's `{enabled}` wrappers back to the PUT shape and sorting arrays. GitHub-added
   defaults are not drift. A field a human set that the policy does not name is not reverted.
   The policy owns what it names.
4. **summon.sh is a writer, so it is dry-run by default** (SPEC I2, TB1 decision 1). The workflow
   passes `--apply`.
5. **Who is "one named human"?** `--to` > `SUMMONER_TO` (repo variable, optional) > the first
   CODEOWNERS owner on the `factory/HALT` line (halt) or the `factory/**` line (gate asks). The
   spec names no desk-rotation file yet. When one exists, the run loop or the workflow passes
   `--to`.
6. **Ticket id in a summons:** `--ticket` > a `Ticket: <id>` line in the Issue or PR body >
   `#<n>`. On a push, the head commit's last `Ticket:` trailer > `commit <sha12>`. **T4's
   mirror should write a `Ticket: <id>` line into each Issue body** so gate asks carry the
   ADLC id.
7. **A push that lifts HALT is not a summons.** The workflow's `paths:` filter fires on deletion
   too. summon.sh checks the pushed tree and exits 0 without posting. The spec routes a lift to
   the digest.
8. **halt-check fails closed:** exit 1 on fetch failure, so a node never reads "unreachable" as
   "not halted". The run loop (build order 2) must claim only on exit 0.

## 5. Facts measured against GitHub (read-only)

```
$ gh api repos/musicofhel/software-factory --jq '{owner: .owner.type, visibility, default_branch}'
{"default_branch":"main","owner":"User","visibility":"public"}
$ gh api repos/musicofhel/software-factory/rulesets
[]
$ gh api repos/musicofhel/software-factory/branches/main/protection
{"message":"Branch not protected",…,"status":"404"}  gh: Branch not protected (HTTP 404)
```
Docs read on 2026-10-24 (WebFetch, read-only):
- REST "Repository rules": the `pull_request` rule's `required_reviewers` is
  `[{file_patterns, minimum_approvals, reviewer: {id, type: "Team"}}]`. The `merge_queue`
  rule takes `check_response_timeout_minutes`, `grouping_strategy` (`ALLGREEN|HEADGREEN`),
  `max_entries_to_build`, `max_entries_to_merge`, `merge_method` (`MERGE|SQUASH|REBASE`),
  `min_entries_to_merge` and `min_entries_to_merge_wait_minutes`.
- "Available rules for rulesets": "This rule [required reviewers] is not available on
  user-owned repositories as they do not contain teams." No rule is keyed on file deletion.
  `file_path_restriction` is a push-ruleset rule.
- Merge queue availability by owner type was **not** stated in the page fetched. It is a
  close-out proof: the first real `--apply` either accepts the ruleset or returns 422.

## 6. Found while building; owned elsewhere

- **TB3:** `janitor.yml` calls `halt-check.sh` bare. Exit 3 would turn the job red. Map exit 3
  to a clean skip. Also note the new exit 1 (fetch failure), which should stay red.
- **TB4:** the mirror writes a `Ticket: <id>` line into each Issue body (decision 6).
- **TB5 (Aaron's kit and Qs):** ADR-0004's options. Whether the merge queue applies on a
  user-owned repo (live at the first `--apply`). `SUMMONER_TO` as an optional repo variable.
  With `required_approving_review_count: 1` and one human owner, Aaron cannot merge his own
  PRs once protection is applied (no self-approval). So the kit must push everything first and
  apply protection after. Summoner on `pull_request` labeled events from forks gets no secrets,
  so gate asks on fork PRs cannot post. Either use `pull_request_target`, which needs care, or
  label the mirrored Issue instead.
