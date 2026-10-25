#!/usr/bin/env bash
# T4 acceptance 3: factory/bin/post-merge.sh finds the tickets named by `Ticket:` trailers in the
# commits merged since its last run, completes each with `adlc ticket complete <id> --write
# --authorize`, appends one line per verified finding to factory/ledger/findings.jsonl, lands one
# commit on main, and refuses to run anywhere but a checkout of main (exit 2). The origin is a
# local bare repo, the store and gate manifest come from the fake adlc. Offline, no keys.
# T18 acceptance 5 (case railed-store): post-merge passes --allow-unsigned (ruling Q1), so it completes
# tickets in a railed store, which the fake adlc, as the real CLI, refuses to write without it.
set -euo pipefail
# shellcheck source=tests/fakes/lib.sh
. "$(dirname "$0")/fakes/lib.sh"

# pm_setup: $WORLD/repo is a clone of the fake origin on main holding the store
# (.adlc/store.json, FAKE_ADLC_STORE), the gate manifest and an empty findings ledger, then:
#   a       a direct commit with `Ticket: T1`
#   merge   "Merge pull request #7" bringing a branch commit with `Ticket: T2`
#   c       a direct commit with `Ticket: scaffold` (an id the store does not hold)
# all pushed. T3 stays open. Pinned clock; the post-merge job runs on a hosted runner.
pm_setup() {
  fakegh_setup
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=dev GIT_AUTHOR_EMAIL=dev@fake GIT_COMMITTER_NAME=dev GIT_COMMITTER_EMAIL=dev@fake
  git clone -q "$FAKE_GH_GIT" "$WORLD/repo" 2>/dev/null
  R="$WORLD/repo"
  git -C "$R" checkout -q main
  mkdir -p "$R/.adlc" "$R/factory/ledger"
  : >"$R/factory/ledger/findings.jsonl"
  : >"$R/.adlc/manifest.jsonl"
  echo '[{"id":"T1","title":"one"},{"id":"T2","title":"two"},{"id":"T3","title":"three"}]' >"$R/.adlc/store.json"
  finding T2 verified F1
  git -C "$R" add -A; git -C "$R" commit -q -m seed
  commit a "Ticket: T1"
  git -C "$R" checkout -q -b ticket/T2/x
  commit b "Ticket: T2"
  git -C "$R" checkout -q main
  git -C "$R" merge -q --no-ff ticket/T2/x -m "Merge pull request #7 from o/ticket/T2/x"
  commit c "Ticket: scaffold"
  git -C "$R" push -q origin main 2>/dev/null
  export FACTORY_ADLC="$FAKES_DIR/adlc" FAKE_ADLC_STORE="$R/.adlc/store.json" RUNNER_ENVIRONMENT=github-hosted FACTORY_NOW=1762000000
}
commit() {  # commit <file> <trailer...>: a one-file commit on the current branch
  echo "$1" >"$R/$1"
  git -C "$R" add "$1"
  local -a m=(-m "add $1")
  local t; for t in "${@:2}"; do m+=(-m "$t"); done
  git -C "$R" commit -q "${m[@]}"
}
# finding <ticket> <verified|killed|needs-human> <id> [revision]: a prosecute gate record, with
# claim, evidence and recommendation text that must never reach the ledger
finding() {
  jq -cn --arg t "$1" --arg k "$2" --arg id "$3" --arg rev "${4:-r1}" \
    '{type: "p5-finding-\($k)", ticket: $t, revision: $rev, lens: "security", adapter: "claude-code",
      ts: "2026-10-24T00:00:00Z",
      finding: {id: $id, category: "correctness", file: "a.sh", line_start: 1, line_end: 2, severity: "high",
                confidence: 0.9, claim: "CLAIM-TEXT-\($id)", evidence: "EVIDENCE-TEXT", recommendation: "REC-TEXT"}}' \
    >>"$R/.adlc/manifest.jsonl"
}
pm() {  # pm <args>: run post-merge in the checkout with no git identity; sets RC, OUT, ERR
  RC=0
  OUT="$(cd "$R" && env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL \
    "$BIN/post-merge.sh" "$@" 2>"$WORLD/err")" || RC=$?
  ERR="$(command cat "$WORLD/err")"
}
completed() { jq -c '[.[] | select(.completed == true) | .id]' "$FAKE_ADLC_STORE"; }
completions() { jq -sc '[.[] | select(.[0:2] == ["ticket", "complete"])]' "$FAKE_ADLC_LOG"; }
ticket_lines() { jq -sc '[.[] | select(.action == "complete") | [.ticket, .result]]' <<<"$OUT"; }
land() { jq -sc '[.[] | select(.action == "land") | .result]' <<<"$OUT"; }
origin_main() { git -C "$FAKE_GH_GIT" rev-parse refs/heads/main; }
state() {  # everything a run could change: origin refs, local refs, the work tree, the store, the log
  git -C "$FAKE_GH_GIT" for-each-ref
  git -C "$R" for-each-ref
  git -C "$R" status --porcelain --untracked-files=all
  sha256sum "$FAKE_ADLC_STORE" "$R/factory/ledger/findings.jsonl" "$R/.adlc/manifest.jsonl"
}
has() { [[ "$1" == *"$2"* ]] || { printf '      [%s] lacks [%s]\n' "$1" "$2"; return 1; }; }
lacks() { [[ "$1" != *"$2"* ]] || { printf '      [%s] has [%s]\n' "$1" "$2"; return 1; }; }

# ---------------------------------------------------------------------------------------------
case_completes() {
  pm_setup
  local head merge; head="$(git -C "$R" rev-parse HEAD)"; merge="$(git -C "$R" rev-parse HEAD~1)"
  echo junk >"$R/stray.txt"              # an untracked file the run must not commit
  pm --apply
  check "exit 0" eq "$RC" 0
  check "T1 and T2 are complete in the store, T3 is not" eq "$(completed)" '["T1","T2"]'
  check "adlc ticket complete <id> --write --authorize --json, once per named ticket, in merge order" \
    eq "$(completions)" '[["ticket","complete","T1","--write","--authorize","--allow-unsigned","--json"],["ticket","complete","T2","--write","--authorize","--allow-unsigned","--json"]]'
  check "an unrailed store takes --allow-unsigned silently: no bypass entry, no warning" \
    eval '[ "$(jq -sc '"'"'[.[] | select(.gate == "ticket-complete") | .data.bypass]'"'"' "$R/.adlc/manifest.jsonl")" = "[null,null]" ] && lacks "$ERR" "UNSIGNED"'
  check "lines: T1 done, T2 done, scaffold unknown (skipped)" eq "$(ticket_lines)" '[["T1","done"],["T2","done"],["scaffold","unknown"]]'
  check "T2's line names its PR and merge commit" \
    eq "$(jq -sc '.[] | select(.ticket == "T2") | [.pr, .commit, .findings]' <<<"$OUT")" "[7,\"$merge\",1]"
  check "T1's line names its direct commit and no PR" \
    eq "$(jq -sc '.[] | select(.ticket == "T1") | [.pr, .commit]' <<<"$OUT")" "[null,\"$(git -C "$R" rev-parse HEAD~3)\"]"
  check "one ledger line, for T2's verified finding" eq "$(jq -sc '[.[] | [.ticket, .finding_id, .pr]]' "$R/factory/ledger/findings.jsonl")" '[["T2","F1",7]]'
  check "the marker names the head the run scanned" eq "$(jq -r .through "$R/factory/ledger/post-merge.json")" "$head"
  check "one new commit on top of that head" eq "$(git -C "$R" rev-parse HEAD~1)" "$head"
  check "the commit holds only the store, the gate manifest and the ledger" \
    eq "$(git -C "$R" diff --name-only HEAD~1 HEAD | sort | tr '\n' ' ')" '.adlc/manifest.jsonl .adlc/store.json factory/ledger/findings.jsonl factory/ledger/post-merge.json '
  check "the commit says what it completed and through which commit" \
    eval 'has "$(git -C "$R" log -1 --format=%B)" "post-merge: complete T1 T2" && has "$(git -C "$R" log -1 --format=%B)" "Through: $head"'
  check "the commit is the post-merge identity's (no git identity was set)" eq "$(git -C "$R" log -1 --format=%an)" factory-post-merge
  check "pushed: origin main is the new commit" eq "$(origin_main)" "$(git -C "$R" rev-parse HEAD)"
  check "a land line, done" eq "$(land)" '["done"]'
  check "the work tree is clean but for the stray file" eq "$(git -C "$R" status --porcelain)" "?? stray.txt"
}

case_refuses_off_main() {
  pm_setup
  git -C "$R" checkout -q -b ticket/T1/alpha
  local before; before="$(state)"
  pm --apply
  check "--apply on a ticket branch: exit 2" eq "$RC" 2
  check "the refusal names main" has "$ERR" "checkout of main"
  pm
  check "a dry run off main: exit 2 too" eq "$RC" 2
  git -C "$R" checkout -q --detach main
  pm --apply
  check "a detached HEAD at main's commit: exit 2" eq "$RC" 2
  check "no adlc call was made" eq "$(wc -l <"$FAKE_ADLC_LOG" | tr -d ' ')" 0
  git -C "$R" checkout -q ticket/T1/alpha
  check "nothing changed" eq "$(state)" "$before"
  RC=0; (cd "$WORLD" && "$BIN/post-merge.sh" 2>/dev/null) || RC=$?
  check "outside any repo: exit 2" eq "$RC" 2
}

case_dry_run_inert() {
  pm_setup
  local before; before="$(state)"
  pm
  check "no flag: exit 0" eq "$RC" 0
  check "no flag: every ticket line planned, the unknown one skipped" eq "$(ticket_lines)" '[["T1","planned"],["T2","planned"],["scaffold","unknown"]]'
  check "no flag: no land line" eq "$(land)" '[]'
  check "no flag: nothing changed (refs, tree, store, ledger, manifest)" eq "$(state)" "$before"
  check "no flag: no completion was attempted" eq "$(completions)" '[]'
  pm --dry-run
  check "--dry-run: exit 0, still nothing changed" eval '[ "$RC" = 0 ] && [ "$(state)" = "$before" ] && [ "$(completions)" = "[]" ]'
  RUNNER_ENVIRONMENT=self-hosted pm --dry-run
  check "a dry run needs no hosted runner" eq "$RC" 0
}

case_findings_ledger() {
  pm_setup
  finding T1 verified K1                 # kept
  finding T1 verified K2; finding T1 killed K2   # verified, then killed: dropped
  finding T1 needs-human K3              # never verified: dropped
  finding T1 verified K4 r1; finding T1 verified K4 r2   # verified twice: one line, the latest
  finding T1 killed K5; finding T1 verified K5   # killed, then verified again: kept
  finding T3 verified K6                 # another ticket's, not completed: not in the ledger
  git -C "$R" commit -qam "findings"; git -C "$R" push -q origin main 2>/dev/null
  pm --apply
  check "exit 0" eq "$RC" 0
  check "T1: K1, K4 (latest revision), K5; T2: F1" \
    eq "$(jq -sc '[.[] | [.ticket, .finding_id, .revision]]' "$R/factory/ledger/findings.jsonl")" \
       '[["T1","K1","r1"],["T1","K4","r2"],["T1","K5","r1"],["T2","F1","r1"]]'
  check "T1's complete line counts 3 findings" eq "$(jq -sc '.[] | select(.ticket == "T1") | .findings' <<<"$OUT")" 3
  local led; led="$(command cat "$R/factory/ledger/findings.jsonl")"
  check "no claim text in the ledger" lacks "$led" "CLAIM-TEXT"
  check "no evidence text in the ledger" lacks "$led" "EVIDENCE-TEXT"
  check "no recommendation text in the ledger" lacks "$led" "REC-TEXT"
  check "no claim, evidence or recommendation key either" \
    eq "$(jq -sc '[.[] | keys[] | select(IN("claim", "evidence", "recommendation", "finding"))] | length' "$R/factory/ledger/findings.jsonl")" 0
  check "a line carries the locator, severity, confidence and provenance" \
    eq "$(jq -sc '.[0] | [.category, .severity, .confidence, .file, .line_start, .line_end, .lens, .adapter, .verified_at, .completed_at]' "$R/factory/ledger/findings.jsonl")" \
       '["correctness","high",0.9,"a.sh",1,2,"security","claude-code","2026-10-24T00:00:00Z","'"$(jq -nr '1762000000 | todate')"'"]'
  check "every line is one JSON object" eq "$(jq -c 'type' "$R/factory/ledger/findings.jsonl" | sort -u)" '"object"'
}

case_range_since_marker() {
  pm_setup
  pm --apply
  check "first run exit 0" eq "$RC" 0
  local led1 head1; led1="$(command cat "$R/factory/ledger/findings.jsonl")"; head1="$(origin_main)"
  git -C "$R" checkout -q -b ticket/T3/y   # a PR whose merge must bring only its own commits
  commit d "Ticket: T3"
  git -C "$R" checkout -q main
  git -C "$R" merge -q --no-ff ticket/T3/y -m "Merge pull request #8 from o/ticket/T3/y"
  commit e "Ticket: T1"                  # names a ticket completed by the first run
  commit f "Ticket: T3"                  # names T3 a second time in the same range
  git -C "$R" push -q origin main 2>/dev/null
  : >"$FAKE_ADLC_LOG"
  pm --apply
  check "second run exit 0" eq "$RC" 0
  check "only the commits since the marker are read: T3 done, T1 already complete" \
    eq "$(ticket_lines)" '[["T3","done"],["T1","already"]]'
  check "T3 is credited to PR #8" eq "$(jq -sc '.[] | select(.ticket == "T3") | .pr' <<<"$OUT")" 8
  check "only T3 is completed again" eq "$(completions)" '[["ticket","complete","T3","--write","--authorize","--allow-unsigned","--json"]]'
  check "no duplicate ledger lines" eq "$(command cat "$R/factory/ledger/findings.jsonl")" "$led1"
  check "the marker advances to the scanned head" eq "$(jq -r .through "$R/factory/ledger/post-merge.json")" "$(git -C "$R" rev-parse HEAD~1)"
  check "the second commit sits on the first run's commit" eq "$(git -C "$R" rev-parse HEAD~4)" "$head1"
  local head2; head2="$(origin_main)"
  : >"$FAKE_ADLC_LOG"
  pm --apply
  check "third run, nothing merged since: exit 0" eq "$RC" 0
  check "no ticket lines" eq "$(ticket_lines)" '[]'
  check "land skipped" eq "$(land)" '["skipped"]'
  check "no push" eq "$(origin_main)" "$head2"
  check "no commit" eq "$(git -C "$R" rev-parse HEAD)" "$head2"
  check "no adlc write" eq "$(completions)" '[]'
  printf '{"through":"%s"}\n' "$(printf '0%.0s' $(seq 40))" >"$R/factory/ledger/post-merge.json"
  pm --apply
  check "a marker naming a commit outside main's history: exit 1" eval '[ "$RC" = 1 ] && has "$ERR" "not in main'"'"'s history"'
}

case_completion_failure() {
  pm_setup
  local head; head="$(git -C "$R" rev-parse HEAD)"
  FAKE_ADLC_FAIL='ticket complete T2' pm --apply
  check "exit 1" eq "$RC" 1
  check "T1 done, T2 failed" eq "$(ticket_lines)" '[["T1","done"],["T2","failed"],["scaffold","unknown"]]'
  check "T1 lands in the store, T2 does not" eq "$(completed)" '["T1"]'
  check "T2's finding is not in the ledger" eq "$(jq -sc '[.[].ticket]' "$R/factory/ledger/findings.jsonl")" '[]'
  check "the marker does not advance (there was none)" eval '[ ! -f "$R/factory/ledger/post-merge.json" ]'
  check "T1's completion is still committed and pushed" eval '[ "$(origin_main)" = "$(git -C "$R" rev-parse HEAD)" ] && [ "$(git -C "$R" rev-parse HEAD~1)" = "$head" ]'
  check "the land line keeps the old marker (null)" eq "$(jq -sc '[.[] | select(.action == "land") | [.through, .result]]' <<<"$OUT")" '[[null,"done"]]'
  pm --apply
  check "the retry: exit 0" eq "$RC" 0
  check "the retry rescans the range: T1 already, T2 done" eq "$(ticket_lines)" '[["T1","already"],["T2","done"],["scaffold","unknown"]]'
  check "the ledger now has T2's finding, once" eq "$(jq -sc '[.[] | [.ticket, .finding_id]]' "$R/factory/ledger/findings.jsonl")" '[["T2","F1"]]'
  check "the marker now advances" eq "$(jq -r .through "$R/factory/ledger/post-merge.json")" "$(git -C "$R" rev-parse HEAD~1)"
  commit d "Ticket: T3"; git -C "$R" push -q origin main 2>/dev/null
  local before; before="$(state)"
  FAKE_ADLC_FAIL='ticket show' pm --apply
  check "a failed read: exit 1, no line, nothing changed" eval '[ "$RC" = 1 ] && [ -z "$OUT" ] && [ "$(state)" = "$before" ]'
  FAKE_ADLC_SKIPPED='[{"line":2,"reason":"bad signature"}]' pm --apply
  check "unreadable gate-manifest entries: exit 1, nothing changed" \
    eval '[ "$RC" = 1 ] && has "$ERR" "unreadable" && [ "$(state)" = "$before" ]'
  # An adlc that exits 0 without applying (here: --write is dropped, so it prints only the plan).
  printf '#!/usr/bin/env bash\nargs=(); for a in "$@"; do [ "$a" = --write ] || args+=("$a"); done\nexec "%s" "${args[@]}"\n' \
    "$FAKES_DIR/adlc" >"$WORLD/adlc-nowrite"
  chmod +x "$WORLD/adlc-nowrite"
  FACTORY_ADLC="$WORLD/adlc-nowrite" pm --apply
  check "exit 0 without {applied: true} is a failed completion: exit 1" eval '[ "$RC" = 1 ] && [ "$(ticket_lines)" = "[[\"T3\",\"failed\"]]" ]'
  check "and nothing lands" eq "$(land)" '["skipped"]'
}

case_railed_store() {
  pm_setup
  # T3 (open) declares the default rail: the store is a frozen trust root, as main's is since TB0.
  local tmp; tmp="$(mktemp)"
  jq 'map(if .id == "T3" then .rails = ["factory/policy/**"] else . end)' "$FAKE_ADLC_STORE" >"$tmp" && mv "$tmp" "$FAKE_ADLC_STORE"
  git -C "$R" commit -q -am "T3 declares a rail"; git -C "$R" push -q origin main 2>/dev/null
  local before; before="$(state)"
  local rc=0; (cd "$R" && "$FAKES_DIR/adlc" ticket complete T1 --write --authorize --json >/dev/null 2>"$WORLD/refused") || rc=$?
  check "the fake adlc refuses the write without --allow-unsigned: exit 2, MANIFEST_KEY_REQUIRED, nothing changed" \
    eval '[ "$rc" = 2 ] && [ "$(jq -r .code "$WORLD/refused")" = MANIFEST_KEY_REQUIRED ] && [ "$(state)" = "$before" ]'
  # An adlc call without the flag (post-merge before T18): every completion fails and nothing lands.
  printf '#!/usr/bin/env bash\nargs=(); for a in "$@"; do [ "$a" = --allow-unsigned ] || args+=("$a"); done\nexec "%s" "${args[@]}"\n' \
    "$FAKES_DIR/adlc" >"$WORLD/adlc-signed-only"
  chmod +x "$WORLD/adlc-signed-only"
  FACTORY_ADLC="$WORLD/adlc-signed-only" pm --apply
  check "without the flag: exit 1, T1 and T2 failed" eval '[ "$RC" = 1 ] && [ "$(ticket_lines)" = "[[\"T1\",\"failed\"],[\"T2\",\"failed\"],[\"scaffold\",\"unknown\"]]" ]'
  check "the failed lines name MANIFEST_KEY_REQUIRED" \
    eq "$(jq -sc '[.[] | select(.result == "failed") | .detail | test("^adlc ticket complete exit 2: .*MANIFEST_KEY_REQUIRED")]' <<<"$OUT")" '[true,true]'
  check "and nothing completes or lands" eval '[ "$(completed)" = "[]" ] && [ "$(land)" = "[\"skipped\"]" ] && [ "$(state)" = "$before" ]'
  : >"$FAKE_ADLC_LOG"
  pm --apply
  check "post-merge as it is: exit 0, T1 and T2 done" eval '[ "$RC" = 0 ] && [ "$(ticket_lines)" = "[[\"T1\",\"done\"],[\"T2\",\"done\"],[\"scaffold\",\"unknown\"]]" ]'
  check "it passed --allow-unsigned on both completions" \
    eq "$(jq -sc '[.[] | select(.[0:2] == ["ticket", "complete"]) | index("--allow-unsigned") != null]' "$FAKE_ADLC_LOG")" '[true,true]'
  check "T1 and T2 complete in the store, T3 open" eq "$(completed)" '["T1","T2"]'
  check "each completion is recorded unsigned (bypass: true)" \
    eq "$(jq -sc '[.[] | select(.gate == "ticket-complete") | [.ticket, .data.bypass]]' "$R/.adlc/manifest.jsonl")" '[["T1",true],["T2",true]]'
  check "the run landed and pushed" eval '[ "$(land)" = "[\"done\"]" ] && [ "$(origin_main)" = "$(git -C "$R" rev-parse HEAD)" ]'
}

case_push_refused() {
  pm_setup
  git clone -q "$FAKE_GH_GIT" "$WORLD/other" 2>/dev/null
  git -C "$WORLD/other" checkout -q main
  echo x >"$WORLD/other/x"; git -C "$WORLD/other" add x; git -C "$WORLD/other" commit -qm "a merge lands mid-run"
  git -C "$WORLD/other" push -q origin main 2>/dev/null
  local moved; moved="$(origin_main)"
  pm --apply
  check "origin main moved: exit 1" eq "$RC" 1
  check "the land line says failed and why" \
    eval '[ "$(land)" = "[\"failed\"]" ] && has "$(jq -sc ".[] | select(.action == \"land\") | .detail" <<<"$OUT")" "refused"'
  check "origin main is left as the other push made it (no force)" eq "$(origin_main)" "$moved"
}

case_refuses_apply_off_hosted() {
  pm_setup
  local before; before="$(state)"
  RUNNER_ENVIRONMENT=self-hosted pm --apply
  check "--apply on a self-hosted runner (a node): exit 2" eval '[ "$RC" = 2 ] && has "$ERR" "GitHub-hosted"'
  (unset RUNNER_ENVIRONMENT; pm --apply; [ "$RC" = 2 ]) && r=ok || r=bad
  check "--apply with RUNNER_ENVIRONMENT unset: exit 2" eq "$r" ok
  check "nothing changed, no adlc call" eval '[ "$(state)" = "$before" ] && [ "$(wc -l <"$FAKE_ADLC_LOG" | tr -d " ")" = 0 ]'
  pm --bogus
  check "an unknown flag: exit 1" eq "$RC" 1
}

# T10 acceptance 3 (step-1 follow-up 2): the completion commit carries the three trailers in one
# paragraph git parses, and the next run passes over it (it names no ticket).
case_trailers() {
  pm_setup
  local head; head="$(git -C "$R" rev-parse HEAD)"
  pm --apply
  check "exit 0" eq "$RC" 0
  check "git interpret-trailers --parse: Through, Assisted-by, Ticket, Node" \
    eq "$(git -C "$R" log -1 --format=%B | git interpret-trailers --parse)" \
       "$(printf 'Through: %s\nAssisted-by: none\nTicket: post-merge\nNode: github-actions' "$head")"
  check "one trailer paragraph (the I6 check reads it)" \
    eq "$(git -C "$R" log -1 --format='%(trailers:key=Ticket,valueonly)%(trailers:key=Node,valueonly)%(trailers:key=Assisted-by,valueonly)' | tr -s '\n' ' ')" \
       "post-merge github-actions none "
  check "no Signed-off-by: no human wrote it" eq "$(git -C "$R" log -1 --format='%(trailers:key=Signed-off-by)')" ""
  commit g "Ticket: T3"
  git -C "$R" push -q origin main 2>/dev/null
  : >"$FAKE_ADLC_LOG"
  pm --apply
  check "the next run reads its own commit but reports only T3" eq "$RC $(ticket_lines)" '0 [["T3","done"]]'
  check "the store is never asked about post-merge" eq "$(jq -sc '[.[] | select(index("post-merge"))]' "$FAKE_ADLC_LOG")" '[]'
}

case_workflow() {
  local wf="$REPO_ROOT/.github/workflows/post-merge.yml"
  check "post-merge.yml runs post-merge.sh --apply (the script is dry-run by default)" grep -q "./factory/bin/post-merge.sh --apply" "$wf"
  check "it checks out main with full history" eval 'grep -A4 "uses: actions/checkout@v4" "$wf" | head -n5 | grep -q "fetch-depth: 0" &&
    grep -A4 "uses: actions/checkout@v4" "$wf" | head -n5 | grep -q "ref: main"'
  # T10 acceptance 5 and ruling Q6: the App token, pinned by commit, with the GITHUB_TOKEN fallback.
  local jw="$REPO_ROOT/.github/workflows/janitor.yml" f
  for f in "$wf" "$jw"; do
    check "$(basename "$f"): every create-github-app-token use is pinned by a 40-hex commit sha" \
      eval '[ "$(grep -c "uses: actions/create-github-app-token@" "$f")" -ge 1 ] &&
            ! grep "uses: actions/create-github-app-token@" "$f" | grep -Eqv "@[0-9a-f]{40} # v[0-9]+\.[0-9]+\.[0-9]+$"'
    check "$(basename "$f"): the App step runs only with FACTORY_APP_ID set and FACTORY_APP_KEY present" \
      eval 'grep -q "HAS_APP_KEY: \${{ secrets.FACTORY_APP_KEY != '"''"' }}" "$f" &&
            grep -q "env.FACTORY_APP_ID != '"''"' && env.HAS_APP_KEY == '"'true'"'" "$f"'
  done
  check "the pinned sha is the same in both workflows" \
    eq "$(grep -ho "create-github-app-token@[0-9a-f]*" "$wf" "$jw" | sort -u | wc -l | tr -d ' ')" 1
  check "the checkout (whose credentials push) takes the App token, else GITHUB_TOKEN" \
    grep -q 'token: ${{ steps.app.outputs.token || github.token }}' "$wf"
  check "no App: a step-summary line says the push is on GITHUB_TOKEN" \
    eval 'grep -A2 "if: steps.app.outcome == '"'skipped'"'" "$wf" | grep -q "pushed on GITHUB_TOKEN.*GITHUB_STEP_SUMMARY"'
  check "the App token asks for contents: write only" eval '[ "$(grep -c "permission-" "$wf")" = 1 ] && grep -q "permission-contents: write" "$wf"'
  check "the mirror job waits for the completion job" grep -Eq "^    needs: complete$" "$wf"
  check "the mirror job shares the concurrency group mirror" eval 'grep -A1 -E "^    concurrency:$" "$wf" | grep -Eq "^      group: mirror$"'
  check "the mirror job applies" grep -q "./factory/bin/mirror.sh --apply" "$wf"
  check "it triggers on pushes to main only" eval 'grep -A2 -E "^  push:$" "$wf" | grep -q "branches: \[main\]"'
}

for c in completes refuses-off-main dry-run-inert findings-ledger range-since-marker completion-failure railed-store push-refused \
         refuses-apply-off-hosted trailers workflow; do
  run_case "$c"
done
[ "$FAILED" = 0 ]
