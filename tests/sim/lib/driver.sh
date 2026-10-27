# shellcheck shell=bash
# The workflow driver of `make sim` (tests/sim/sim.sh sources this; never executed). It plays GitHub
# Actions for one event against the sim world: it reads .github/workflows/*.yml from the commit
# GitHub reads them from, with yq (mikefarah v4, also on ubuntu-latest), matches `on:` (types,
# branches, paths), runs every matching job in `needs` order with the runner's env and event JSON,
# evaluates `if:`, `env:`, `with:` and `run:` expressions with lib/expr.jq, and records each job's
# conclusion as a check run named by the bare job id (records/TB0.md (b)) in the fake gh state.
# The job list always comes from the YAML: a job a later row adds is run without editing this file.
#
#   drive <event> <event-json-file> <workflow-sha> [only-workflow-file]
#       Needs from the caller: SIM (scratch dir), ORIGIN (bare repo), REPO (owner/name),
#       RUNNER_PATH (runner shims first), SIM_LIB (this dir), FAKE_GH_* for the fake gh,
#       SIM_VARS (a JSON object: the repo variables) and SIM_SECRETS (a JSON object).
#       The event JSON carries what GitHub's does; GITHUB_SHA/REF come from it:
#         pull_request  {action, number, pull_request: {number, head: {ref, sha}, base: {ref, sha}}}
#                       GITHUB_SHA = refs/pull/<n>/merge (the caller builds it, pr_merge_ref)
#         merge_group   {action: checks_requested, merge_group: {head_sha, head_ref, base_sha, base_ref}}
#         push          {ref, before, after}
#         schedule      {schedule: <cron>}       (only-workflow-file names the workflow)
#         issues        {action, label: {name}, issue: {number}}
#         pull_request_review  {action: submitted|dismissed, review: {...}, pull_request: {number, head, base}}:
#                       GITHUB_SHA/REF as pull_request (refs/pull/<n>/merge)
#         pull_request_target  {action, number, pull_request: {...}, [reason]}: GITHUB_SHA/REF = the base
#                       branch's tip (workflows from there: the caller passes main's sha)
#         workflow_run  {action: completed, workflow_run: {id, name, path, event, head_sha, head_branch,
#                       conclusion}}: the driver fires it itself, never a caller (below)
#       A job's `outputs:` are evaluated on its steps once it ran (needs.<job>.outputs). A job-level
#       `uses: ./.github/workflows/<f>` (workflow_call) runs <f> from the caller's workflow commit with the
#       `inputs` context (the caller's `with:`, then on.workflow_call.inputs defaults), the caller's
#       github context and only GITHUB_TOKEN of the secrets (`secrets: inherit` passes them all); its
#       jobs are the caller run's jobs and check runs, named `<caller job> / <job>` as GitHub names
#       them, and jobs.jsonl lines with `call: {caller, workflow, inputs}`; the caller's result is
#       failure when any called job failed, else success.
#       GitHub's push events for pushes a job makes: a job whose step minted the App token (an output
#       token == ghs_sim_app_token, lib's create-github-app-token) and created or moved a refs/heads/*
#       ref of the origin queues one push event per ref ($SIM/push-queue.jsonl; deletions start none),
#       played by the outermost drive with the re-runs (a GITHUB_TOKEN push starts no workflow,
#       records/TB0.md (d)). When a job moves main, every open PR on main whose head is now reachable
#       from it is marked merged, `.merged += {pr, sha: <new main>}` and `.merged_marks` (GitHub's
#       indirect merge; its merge_commit_sha is undocumented, a kit line, TB12).
#       SIM_STANDIN_GREEN (job ids, space-separated; the caller's labeled stand-in; unused since TB11, T30): a job of that id
#       that failed is success in GitHub's view (.runs, .checks, needs, the caller's result), while
#       jobs.jsonl keeps the real conclusion plus `standin: true`; sim.log says `stand-in:`.
#       Each run is also recorded as GitHub's Actions API answers it: `.runs` of the fake gh state
#       ({id, name, path, event, head_sha, head_branch, created_at, run_attempt, jobs: [{id, name,
#       status, conclusion, started_at, completed_at}]}, ids and times from the `.seq` counter on the
#       pinned clock FAKE_GH_NOW), with the sim's own `_`-keys to replay a job.
#       After the workflows of an event ran, every one of them `completed` fires `workflow_run` for the
#       workflows of main's tip that name it (GitHub reads workflow_run workflows from the default
#       branch). One level: a workflow_run run fires none (GitHub allows three; nothing here chains).
#       Last, the outermost drive plays every job re-run requested meanwhile (POST
#       actions/jobs/<id>/rerun appends to `.reruns`): the job runs again with its run's original
#       event, sha and workflow file ("Re-runs use ... the same GITHUB_SHA (commit SHA) and
#       GITHUB_REF (git ref) of the original event", GitHub docs, re-run workflows and jobs), a new
#       job id replaces the old one in its run, run_attempt + 1, and a new check run is recorded; a
#       second request for a job already re-run is skipped (GitHub refuses a re-run of a queued run).
#       A job with `environment: <name>` runs only from a ref SIM_ENVIRONMENTS[<name>].branches allows
#       (a JSON object {<name>: {branches: [..] | null (any), secrets: {..}}}; an environment it does not
#       name allows any ref and adds no secret), and fails as GitHub does otherwise; the environment's
#       secrets join the job's secrets context.
#       Each job's `run:` steps see PATH = <job>.pipx-bin:RUNNER_PATH and PIPX_BIN_DIR = that dir,
#       fresh per job (GitHub: PIPX_BIN_DIR=/opt/pipx_bin on PATH, one VM per job).
#       Appends one JSON line per job to $SIM/jobs.jsonl: {workflow, job, event, conclusion, head_sha,
#       log} (+ standin, call; a workflow_call caller's own line carries `uses`).
#       Returns 0; a driver error (an action it cannot emulate, a bad expression) exits 1 loudly.
#   pr_merge_ref <n> <base-sha> <head-sha>   builds refs/pull/<n>/merge as GitHub does (merge-tree);
#       prints its sha, or nothing on a conflict (GitHub runs no pull_request workflow then)

drv_die() { printf 'sim driver: %s\n' "$*" >&2; exit 1; }

# The expression evaluator: xjq <ctx-file> <jq program using ev/tmpl/has_status> [jq args...]
xjq() { local c="$1" p="$2"; shift 2; jq -r -L "$SIM_LIB" "$@" 'include "expr"; '"$p" "$c"; }

pr_merge_ref() {
  local n="$1" base="$2" head="$3" tree sha
  tree="$(git -C "$ORIGIN" merge-tree --write-tree "$base" "$head" 2>/dev/null)" || return 0
  sha="$(printf 'Merge %s into %s\n' "$head" "$base" | GIT_AUTHOR_NAME=GitHub GIT_AUTHOR_EMAIL=noreply@github.com \
         GIT_COMMITTER_NAME=GitHub GIT_COMMITTER_EMAIL=noreply@github.com \
         git -C "$ORIGIN" commit-tree "$tree" -p "$base" -p "$head")"
  git -C "$ORIGIN" update-ref "refs/pull/$n/merge" "$sha"
  printf '%s\n' "$sha"
}

# Every workflow at <sha> as one JSON array [{file, wf}], `on:` normalized to an object.
wf_all() {
  local sha="$1" f
  git -C "$ORIGIN" ls-tree --name-only "$sha" .github/workflows/ | while IFS= read -r f; do
    case "$f" in *.yml|*.yaml) ;; *) continue ;; esac
    git -C "$ORIGIN" show "$sha:$f" | yq -o=json '.' | jq -c --arg f "$f" '{file: $f, wf: .}'
  done | jq -sc 'map(.wf.on |= (if type == "string" then {(.): null} elif type == "array" then (map({(.): null}) | add)
                                 else . end))'
}

# Does workflow `on:` match? Pure jq over {on, event, payload, files}.
MATCH_JQ='
def gre: "^" + (gsub("\\."; "\\.") | gsub("\\*\\*"; "\u0001") | gsub("\\*"; "[^/]*") | gsub("\u0001"; ".*")) + "$";
def any_glob($pats; $s): any($pats[]; . as $p | $s | test($p | gre));
def filt($cfg; $key; $vals):
  if $cfg == null or $cfg[$key] == null then true else any($vals[]; any_glob($cfg[$key]; .)) end;
.event as $ev | .on[$ev] as $cfg
| if (.on | has($ev)) | not then false
  else
    (if $cfg != null and $cfg.types != null then (.payload.action | IN($cfg.types[]))
     elif .event | IN("pull_request", "pull_request_target") then (.payload.action | IN("opened", "synchronize", "reopened"))
     else true end)
    and (if .event | IN("pull_request", "pull_request_target") then filt($cfg; "branches"; [.payload.pull_request.base.ref])
         elif .event == "push" then filt($cfg; "branches"; [.payload.ref | sub("^refs/heads/"; "")])
         elif .event == "workflow_run" then
           (.payload.workflow_run.name | IN(($cfg.workflows // [])[]))
           and filt($cfg; "branches"; [.payload.workflow_run.head_branch])
         else true end)
    and (if .event | IN("pull_request", "pull_request_target", "push") then
           (if $cfg == null or $cfg.paths == null then true else any(.files[]; any_glob($cfg.paths; .)) end)
         else true end)
  end'

# The jobs of one workflow in `needs` order (Kahn), as job ids.
JOB_ORDER_JQ='
.jobs as $j | ($j | keys_unsorted) as $ids
| {done: [], out: []}
| until((.done | length) == ($ids | length);
    .done as $d
    | [$ids[] as $i | select(($i | IN($d[])) | not)
       | select(all(($j[$i].needs // [] | if type == "string" then [.] else . end)[]; IN($d[]))) | $i] as $w
    | if ($w | length) == 0 then error("needs cycle") else .done += $w | .out += $w end)
| .out[]'

DRV_DEPTH=0
drive() {
  local event="$1" evfile="$2" wsha="$3" only="${4:-}"
  local all n i file wf payload files="[]" sha ref base_ref="" head_ref="" head_sha done_runs=() r
  payload="$(jq -c . "$evfile")"
  case "$event" in
    pull_request)
      local pn; pn="$(jq -r .number <<<"$payload")"
      sha="$(git -C "$ORIGIN" rev-parse "refs/pull/$pn/merge")" || drv_die "no refs/pull/$pn/merge"
      ref="refs/pull/$pn/merge"; base_ref="$(jq -r .pull_request.base.ref <<<"$payload")"
      head_ref="$(jq -r .pull_request.head.ref <<<"$payload")"; head_sha="$(jq -r .pull_request.head.sha <<<"$payload")"
      files="$(git -C "$ORIGIN" diff --name-only "$(jq -r .pull_request.base.sha <<<"$payload")...$head_sha" | jq -Rsc 'split("\n")[:-1]')" ;;
    pull_request_review)
      local rn; rn="$(jq -r .pull_request.number <<<"$payload")"
      sha="$(git -C "$ORIGIN" rev-parse "refs/pull/$rn/merge")" || drv_die "no refs/pull/$rn/merge"
      ref="refs/pull/$rn/merge"; base_ref="$(jq -r .pull_request.base.ref <<<"$payload")"
      head_ref="$(jq -r .pull_request.head.ref <<<"$payload")"; head_sha="$(jq -r .pull_request.head.sha <<<"$payload")" ;;
    pull_request_target)
      base_ref="$(jq -r .pull_request.base.ref <<<"$payload")"; head_ref="$(jq -r .pull_request.head.ref <<<"$payload")"
      sha="$(git -C "$ORIGIN" rev-parse "refs/heads/$base_ref")" || drv_die "pull_request_target: no base branch $base_ref"
      ref="refs/heads/$base_ref"; head_sha="$sha"
      files="$(git -C "$ORIGIN" diff --name-only "$sha...$(jq -r .pull_request.head.sha <<<"$payload")" | jq -Rsc 'split("\n")[:-1]')" ;;
    merge_group)
      sha="$(jq -r .merge_group.head_sha <<<"$payload")"; ref="$(jq -r .merge_group.head_ref <<<"$payload")"; head_sha="$sha" ;;
    push)
      local before; before="$(jq -r .before <<<"$payload")"
      sha="$(jq -r .after <<<"$payload")"; ref="$(jq -r .ref <<<"$payload")"; head_sha="$sha"
      # A created branch (before = 0…0): the paths of its tip commit.
      if [[ "$before" =~ ^0+$ ]]; then files="$(git -C "$ORIGIN" diff-tree --no-commit-id --name-only -r --root "$sha" | jq -Rsc 'split("\n")[:-1]')"
      else files="$(git -C "$ORIGIN" diff --name-only "$before" "$sha" | jq -Rsc 'split("\n")[:-1]')"; fi ;;
    schedule|issues|workflow_dispatch|workflow_run)
      sha="$(git -C "$ORIGIN" rev-parse refs/heads/main)"; ref=refs/heads/main; head_sha="$sha" ;;
    *) drv_die "event $event is not simulated" ;;
  esac
  # A commit's workflows never change: the last sha's list is reused (every workflow_run reads main's).
  if [ "$wsha" != "${DRV_ALL_SHA:-}" ]; then DRV_ALL="$(wf_all "$wsha")"; DRV_ALL_SHA="$wsha"; fi
  all="$DRV_ALL"
  n="$(jq length <<<"$all")"
  for ((i = 0; i < n; i++)); do
    file="$(jq -r ".[$i].file" <<<"$all")"
    [ -z "$only" ] || [ "$file" = "$only" ] || continue
    wf="$(jq -c ".[$i].wf" <<<"$all")"
    if [ "$event" = schedule ]; then
      jq -e '.on | has("schedule")' <<<"$wf" >/dev/null || continue
    else
      jq -e --arg e "$event" --argjson p "$payload" --argjson f "$files" '{on, event: $e, payload: $p, files: $f} | '"$MATCH_JQ" \
        <<<"$wf" >/dev/null || continue
    fi
    DRV_DEPTH=$((DRV_DEPTH + 1))
    run_workflow "$file" "$wf" "$event" "$payload" "$sha" "$ref" "$base_ref" "$head_ref" "$head_sha" "$wsha"
    DRV_DEPTH=$((DRV_DEPTH - 1))
    done_runs+=("$DRV_RUN_ID")
  done
  if [ "$event" != workflow_run ]; then
    for r in "${done_runs[@]+"${done_runs[@]}"}"; do
      jq -c --argjson id "$r" '.runs[] | select(.id == $id)
        | {action: "completed", workflow_run: ({id, name, path, event, head_sha, head_branch}
           + {conclusion: (if any(.jobs[]; .conclusion == "failure") then "failure" else "success" end)})}' \
        "$FAKE_GH_ISSUES" >"$SIM/ev-wfrun.json"
      DRV_DEPTH=$((DRV_DEPTH + 1))
      drive workflow_run "$SIM/ev-wfrun.json" "$(git -C "$ORIGIN" rev-parse refs/heads/main)"
      DRV_DEPTH=$((DRV_DEPTH - 1))
    done
  fi
  [ "$DRV_DEPTH" != 0 ] || drv_settle
}

# The outermost drive's tail: every App push event queued meanwhile (oldest first, each with its own
# workflow_run), then every job re-run requested (POST actions/jobs/<id>/rerun), until neither is left.
drv_settle() {
  local ev
  while :; do
    if [ -s "$SIM/push-queue.jsonl" ]; then
      ev="$(head -n1 "$SIM/push-queue.jsonl")"
      sed -i 1d "$SIM/push-queue.jsonl"
      jq -c '{ref, before, after}' <<<"$ev" >"$SIM/ev-app-push.json"
      printf 'sim driver: push event %s %s → %s (pushed by %s on the App token)\n' "$(jq -r .ref <<<"$ev")" \
        "$(jq -r '.before[0:12]' <<<"$ev")" "$(jq -r '.after[0:12]' <<<"$ev")" "$(jq -r .by <<<"$ev")" >>"$SIM/sim.log"
      DRV_DEPTH=1
      drive push "$SIM/ev-app-push.json" "$(jq -r .after <<<"$ev")"
      DRV_DEPTH=0
    elif [ "$(jq '(.reruns // []) | length' "$FAKE_GH_ISSUES")" != 0 ]; then
      play_rerun
    else
      break
    fi
  done
}

gh_seq() {  # gh_seq: the next id of the fake gh state's `.seq` counter (run ids, job ids, clock ticks)
  gh_state '.seq = ((.seq // 0) + 1)'
  jq -r .seq "$FAKE_GH_ISSUES"
}
gh_time() { jq -nr --argjson s "$1" --argjson t "${FAKE_GH_NOW:-0}" '$t + $s | todate'; }

# The oldest job re-run requested (`.reruns`).
play_rerun() {
  local jid run job wdir nwdir res gres started nid
  {
    jid="$(jq -r '.reruns[0]' "$FAKE_GH_ISSUES")"
    gh_state '.reruns = .reruns[1:]'
    run="$(jq -c --argjson j "$jid" '.runs[] | select(any(.jobs[]; .id == $j))' "$FAKE_GH_ISSUES")"
    if [ -z "$run" ] && jq -e --argjson j "$jid" 'any(.runs[]?; ._rerun_of[$j | tostring] != null)' "$FAKE_GH_ISSUES" >/dev/null; then
      # A second request for a job already re-run in this settle: GitHub refuses a re-run while the
      # run's re-run is queued, and the sim plays every request only after the event.
      printf 'sim driver: re-run of job %s skipped: it was re-run already (a duplicate request)\n' "$jid" >>"$SIM/sim.log"
      return 0
    fi
    [ -n "$run" ] || drv_die "re-run of job $jid: no run holds it"
    job="$(jq -r --argjson j "$jid" '.jobs[] | select(.id == $j) | .name' <<<"$run")"
    local file wf; file="$(jq -r ._file <<<"$run")"
    wf="$(git -C "$ORIGIN" show "$(jq -r ._wsha <<<"$run"):$file" | yq -o=json '.' | jq -c .)"
    jq -e --arg j "$job" '.jobs[$j].needs == null' <<<"$wf" >/dev/null ||
      drv_die "re-run of $file/$job: a job with needs is not simulated"
    wdir="$(jq -r ._wdir <<<"$run")"; nwdir="$(mktemp -d "$SIM/run.XXXXXX")"
    cp "$wdir/event.json" "$wdir/ctx0.json" "$nwdir/"
    DRV_RUN_ID="$(jq .id <<<"$run")" DRV_WSHA="$(jq -r ._wsha <<<"$run")" DRV_HEAD_SHA="$(jq -r .head_sha <<<"$run")"
    started="$(gh_seq)"
    res="$(run_job "$file" "$wf" "$job" "$(jq -r .event <<<"$run")" "$nwdir" '{}' "$(jq -r ._sha <<<"$run")" \
           "$(jq -r ._ref <<<"$run")" "$(jq -r ._base_ref <<<"$run")" "$(jq -r ._head_ref <<<"$run")")"
    nid="$(gh_seq)"
    gres="$(drv_standin "$file" "$job" "$res")"
    gh_state '(.runs[] | select(.id == $r)) |= (.run_attempt += 1 | ._rerun_of[$j | tostring] = $n | .jobs |= map(if .id == $j then
                {id: $n, name, status: "completed", conclusion: $c, started_at: $s, completed_at: $e} else . end))
              | .checks = ((.checks // []) + [{name: $jn, workflow: $w, event: $ev, head_sha: $h, conclusion: $c}])' \
      --argjson r "$DRV_RUN_ID" --argjson j "$jid" --argjson n "$nid" --arg c "$gres" \
      --arg s "$(gh_time "$started")" --arg e "$(gh_time "$nid")" \
      --arg jn "$job" --arg w "$file" --arg ev "$(jq -r .event <<<"$run")" --arg h "$DRV_HEAD_SHA"
    jq -cn --arg w "$file" --arg j "$job" --arg e "$(jq -r .event <<<"$run")" --arg c "$res" --arg g "$gres" --arg h "$DRV_HEAD_SHA" \
      --arg l "$nwdir/$job.log" '{workflow: $w, job: $j, event: $e, conclusion: $c, head_sha: $h, log: $l, rerun: true}
        + (if $g != $c then {standin: true} else {} end)' >>"$SIM/jobs.jsonl"
    printf 'sim driver: re-ran %s/%s (job %s → %s): %s\n' "$file" "$job" "$jid" "$nid" "$res" >>"$SIM/sim.log"
  }
}

# drv_standin <file> <job> <conclusion>: GitHub's view of the conclusion: success for a failed job named in
# SIM_STANDIN_GREEN (the caller's labeled stand-in), else the conclusion itself.
drv_standin() {
  if [ "$3" = failure ] && [[ " ${SIM_STANDIN_GREEN:-} " == *" $2 "* ]]; then
    printf '  stand-in: %s/%s failed; GitHub sees success (SIM_STANDIN_GREEN)\n' "$1" "$2" >>"$SIM/sim.log"
    echo success
  else
    echo "$3"
  fi
}

# drv_outputs <job-def> <job ctx file>: the job's `outputs:`, evaluated on the steps it ran ({} for none).
drv_outputs() {
  local o; o="$(jq -c '.outputs // {}' <<<"$1")"
  if [ "$o" = '{}' ] || [ ! -f "$2" ]; then echo '{}'; return; fi
  jq -c '{ctx: ., status: {success: true, failure: false}}' "$2" |
    jq -c -L "$SIM_LIB" --argjson o "$o" 'include "expr"; . as $in | $o | map_values(tostring as $v | $in | tmpl($v))' ||
    drv_die "bad outputs: expression in $(jq -c . <<<"$o")"
}

# drv_record <file> <check name> <job> <event> <conclusion> <GitHub's conclusion> <log> <started seq> <job seq>
# [extra json]: one job of the run DRV_RUN_ID as GitHub records it (the run's job and a check run, both
# named <check name>, on DRV_HEAD_SHA) and as the sim keeps it (a jobs.jsonl line, the real conclusion).
drv_record() {
  local extra="${10:-}"; [ -n "$extra" ] || extra='{}'
  gh_state '(.runs[] | select(.id == $r)).jobs += [{id: $j, name: $n, status: "completed", conclusion: $c,
              started_at: $s, completed_at: $e}]
            | .checks = ((.checks // []) + [{name: $n, workflow: $w, event: $ev, head_sha: $h, conclusion: $c}])' \
    --argjson r "$DRV_RUN_ID" --argjson j "$9" --arg n "$2" --arg c "$6" --arg s "$(gh_time "$8")" --arg e "$(gh_time "$9")" \
    --arg w "$1" --arg ev "$4" --arg h "$DRV_HEAD_SHA"
  jq -cn --arg w "$1" --arg j "$3" --arg e "$4" --arg c "$5" --arg g "$6" --arg h "$DRV_HEAD_SHA" --arg l "$7" --argjson x "$extra" \
    '{workflow: $w, job: $j, event: $e, conclusion: $c, head_sha: $h, log: $l} + (if $g != $c then {standin: true} else {} end) + $x' \
    >>"$SIM/jobs.jsonl"
}

# drv_pushes <file> <job> <job ctx file> <refs before>: what the job pushed to refs/heads/* of the origin.
# On the App token each created or moved ref queues GitHub's push event (drv_settle plays it); a
# deletion starts none. A move of main marks the PRs it merged (drv_merged_mark).
drv_pushes() {
  local app=0 r b a
  jq -e 'any(.steps[]?; .outputs.token == "ghs_sim_app_token")' "$3" >/dev/null && app=1
  while read -r r b a; do
    [ -n "$r" ] || continue
    if [ "$app" = 1 ]; then
      jq -cn --arg r "$r" --arg b "$b" --arg a "$a" --arg by "$1/$2" '{ref: $r, before: $b, after: $a, by: $by}' >>"$SIM/push-queue.jsonl"
      printf 'sim driver: %s/%s pushed %s %s → %s on the App token: push event queued\n' "$1" "$2" "$r" "${b:0:12}" "${a:0:12}" >>"$SIM/sim.log"
    else
      printf 'sim driver: %s/%s pushed %s %s → %s on GITHUB_TOKEN: no push event\n' "$1" "$2" "$r" "${b:0:12}" "${a:0:12}" >>"$SIM/sim.log"
    fi
    [ "$r" != refs/heads/main ] || drv_merged_mark "$a" "$1/$2"
  done < <(awk -v z=0000000000000000000000000000000000000000 '
             NR == FNR { if ($1 != "") b[$1] = $2; next }
             !($1 in b) { print $1, z, $2; next }
             b[$1] != $2 { print $1, b[$1], $2 }' <(printf '%s\n' "$4") <(git -C "$ORIGIN" for-each-ref --format='%(refname) %(objectname)' refs/heads/))
}

# drv_merged_mark <new main> <by>: GitHub marks a PR merged when its head commits become reachable from
# the base outside the PR ("About pull request merges"); its merge_commit_sha then is undocumented, and
# modeled as the new main (kit, TB12).
drv_merged_mark() {
  local n h
  while read -r n h; do
    [ -n "$h" ] && git -C "$ORIGIN" merge-base --is-ancestor "$h" "$1" 2>/dev/null || continue
    gh_state '(.pulls[] | select(.number == $n)).state = "MERGED" | .merged = ((.merged // []) + [{pr: $n, sha: $s}])
              | .merged_marks = ((.merged_marks // []) + [{pr: $n, sha: $s, by: $by}])' --argjson n "$n" --arg s "$1" --arg by "$2"
    printf 'sim driver: #%s marked merged: its head %s is reachable from main %s (%s)\n' "$n" "${h:0:12}" "${1:0:12}" "$2" >>"$SIM/sim.log"
  done < <(jq -r '(.pulls // [])[] | select(.state == "OPEN" and (.baseRefName // "main") == "main") | "\(.number) \(.headRefOid // "")"' "$FAKE_GH_ISSUES")
}

# run_call <file> <caller job> <job-def> <caller ctx file> <event> <sha> <ref> <base_ref> <head_ref>: a job-level
# `uses: ./.github/workflows/<f>` (workflow_call), the called workflow read at DRV_WSHA; prints the
# caller's result (failure when a called job failed in GitHub's view, else success).
run_call() {
  local file="$1" caller="$2" jdef="$3" ctx="$4" event="$5" sha="$6" ref="$7" base_ref="$8" head_ref="$9"
  local uses cfile cwf with inputs cwdir cj cdef res gres outs started jid cneeds='{}' failed=0
  uses="$(jq -r .uses <<<"$jdef")"
  case "$uses" in
    ./.github/workflows/*.yml|./.github/workflows/*.yaml) cfile="${uses#./}" ;;
    *) drv_die "$file/$caller: uses: $uses (only a local workflow is simulated)" ;;
  esac
  cwf="$(git -C "$ORIGIN" show "$DRV_WSHA:$cfile" | yq -o=json '.' |
         jq -c '.on |= (if type == "string" then {(.): null} elif type == "array" then (map({(.): null}) | add) else . end)')" ||
    drv_die "$file/$caller: $cfile is not readable at ${DRV_WSHA:0:12}"
  jq -e '.on | has("workflow_call")' <<<"$cwf" >/dev/null || drv_die "$file/$caller: $cfile has no on.workflow_call"
  with="$(jq -c '{ctx: ., status: {success: true, failure: false}}' "$ctx" |
          jq -c -L "$SIM_LIB" --argjson j "$jdef" 'include "expr"; . as $in | ($j.with // {}) | map_values(tostring as $v | $in | tmpl($v))')" ||
    drv_die "$file/$caller: bad with: expression"
  # GitHub's inputs: the caller's value, else the default, else the type's empty value; typed.
  inputs="$(jq -c --argjson w "$with" '(.on.workflow_call.inputs // {}) as $d
    | (($w | keys) - ($d | keys)) as $x
    | if ($x | length) > 0 then error("unknown input(s) \($x | join(","))") else . end
    | [$d | to_entries[] | .key as $k | .value as $v
       | if ($w | has($k)) then {key: $k, value: $w[$k]}
         elif ($v | has("default")) then {key: $k, value: $v.default}
         elif $v.required == true then error("input \($k) is required")
         else {key: $k, value: (if $v.type == "boolean" then false elif $v.type == "number" then 0 else "" end)} end
       | .value |= (if $v.type == "boolean" then (if type == "string" then . == "true" else . end)
                    elif $v.type == "number" then (if type == "string" then tonumber else . end)
                    else (if type == "string" then . else tostring end) end)]
    | from_entries' <<<"$cwf")" || drv_die "$file/$caller: the inputs of $cfile"
  cwdir="$(mktemp -d "$SIM/run.XXXXXX")"
  command cp "$(dirname "$ctx")/event.json" "$cwdir/"
  case "$(jq -c '.secrets // null' <<<"$jdef")" in
    null) jq --argjson i "$inputs" '.inputs = $i | .secrets = {GITHUB_TOKEN: .secrets.GITHUB_TOKEN}' "$(dirname "$ctx")/ctx0.json" ;;
    '"inherit"') jq --argjson i "$inputs" '.inputs = $i' "$(dirname "$ctx")/ctx0.json" ;;
    *) drv_die "$file/$caller: secrets: other than inherit is not simulated" ;;
  esac >"$cwdir/ctx0.json"
  printf 'calls %s with inputs %s (jobs in %s)\n' "$cfile" "$inputs" "$cwdir" >>"$(dirname "$ctx")/$caller.log"
  while IFS= read -r cj; do
    cdef="$(jq -c --arg j "$cj" '.jobs[$j]' <<<"$cwf")"
    if jq -e 'has("uses")' <<<"$cdef" >/dev/null; then drv_die "$cfile/$cj: a nested workflow call is not simulated"; fi
    started="$(gh_seq)"
    res="$(run_job "$cfile" "$cwf" "$cj" "$event" "$cwdir" "$cneeds" "$sha" "$ref" "$base_ref" "$head_ref")"
    jid="$(gh_seq)"
    gres="$(drv_standin "$cfile" "$cj" "$res")"
    outs="$(drv_outputs "$cdef" "$cwdir/$cj.ctx.json")"
    drv_record "$cfile" "$caller / $cj" "$cj" "$event" "$res" "$gres" "$cwdir/$cj.log" "$started" "$jid" \
      "$(jq -cn --arg c "$caller" --arg w "$file" --argjson i "$inputs" '{call: {caller: $c, workflow: $w, inputs: $i}}')"
    cneeds="$(jq -c --arg j "$cj" --arg r "$gres" --argjson o "$outs" '.[$j] = {result: $r, outputs: $o}' <<<"$cneeds")"
    [ "$gres" != failure ] || failed=1
  done < <(jq -r "$JOB_ORDER_JQ" <<<"$cwf")
  if [ "$failed" = 1 ]; then echo failure; else echo success; fi
}

run_workflow() {
  local file="$1" wf="$2" event="$3" payload="$4" sha="$5" ref="$6" base_ref="$7" head_ref="$8" head_sha="$9" wsha="${10}"
  local wdir job needs="{}" res rid started jid head_branch
  wdir="$(mktemp -d "$SIM/run.XXXXXX")"
  # The run as the Actions API lists it: a pull_request run's head_branch is the PR's head ref.
  rid="$(gh_seq)"; DRV_RUN_ID="$rid"
  head_branch="$head_ref"; [ -n "$head_branch" ] || head_branch="${ref#refs/heads/}"
  gh_state '.runs = ((.runs // []) + [{id: $id, name: $n, path: $f, event: $e, head_sha: $h, head_branch: $hb,
              created_at: $at, run_attempt: 1, jobs: [], _file: $f, _wsha: $ws, _wdir: $wd, _sha: $sha, _ref: $ref,
              _base_ref: $br, _head_ref: $hr}])' \
    --argjson id "$rid" --arg n "$(jq -r '.name // ""' <<<"$wf")" --arg f "$file" --arg e "$event" --arg h "$head_sha" \
    --arg hb "$head_branch" --arg at "$(gh_time "$rid")" --arg ws "$wsha" --arg wd "$wdir" --arg sha "$sha" --arg ref "$ref" \
    --arg br "$base_ref" --arg hr "$head_ref"
  printf '%s\n' "$payload" >"$wdir/event.json"
  jq -n --arg e "$event" --argjson p "$payload" --arg sha "$sha" --arg ref "$ref" --arg r "$REPO" \
     --arg br "$base_ref" --arg hr "$head_ref" --argjson vars "$SIM_VARS" --argjson sec "$SIM_SECRETS" --argjson wf "$wf" '
    {github: {event_name: $e, event: $p, sha: $sha, ref: $ref, repository: $r, token: "ghs_sim_github_token",
              base_ref: $br, head_ref: $hr, workflow: ($wf.name // "")},
     env: {}, vars: $vars, secrets: ($sec + {GITHUB_TOKEN: "ghs_sim_github_token"}), inputs: {}, steps: {}, needs: {},
     job: {}, runner: {os: "Linux", temp: ""}, matrix: {}}' >"$wdir/ctx0.json"
  DRV_WSHA="$wsha" DRV_HEAD_SHA="$head_sha"
  local jdef gres outs
  while IFS= read -r job; do
    jdef="$(jq -c --arg j "$job" '.jobs[$j]' <<<"$wf")"
    started="$(gh_seq)"
    res="$(run_job "$file" "$wf" "$job" "$event" "$wdir" "$needs" "$sha" "$ref" "$base_ref" "$head_ref")"
    jid="$(gh_seq)"
    gres="$(drv_standin "$file" "$job" "$res")"
    outs="$(drv_outputs "$jdef" "$wdir/$job.ctx.json")"
    if jq -e 'has("uses")' <<<"$jdef" >/dev/null && [ "$res" != skipped ]; then
      # A workflow_call caller is no job of its own in GitHub's view: its called jobs are (run_call).
      jq -cn --arg w "$file" --arg j "$job" --arg e "$event" --arg c "$res" --arg h "$head_sha" --arg l "$wdir/$job.log" \
        --arg u "$(jq -r .uses <<<"$jdef")" '{workflow: $w, job: $j, event: $e, conclusion: $c, head_sha: $h, log: $l, uses: $u}' >>"$SIM/jobs.jsonl"
    else
      drv_record "$file" "$job" "$job" "$event" "$res" "$gres" "$wdir/$job.log" "$started" "$jid"
    fi
    needs="$(jq -c --arg j "$job" --arg r "$gres" --argjson o "$outs" '.[$j] = {result: $r, outputs: $o}' <<<"$needs")"
  done < <(jq -r "$JOB_ORDER_JQ" <<<"$wf")
}

gh_state() {  # gh_state <jq program> [args]: read-modify-write of the fake gh state (FAKE_GH_ISSUES)
  local prog="$1" tmp; shift
  tmp="$(mktemp "$FAKE_GH_ISSUES.XXXXXX")"
  jq "$@" "$prog" "$FAKE_GH_ISSUES" >"$tmp" && mv "$tmp" "$FAKE_GH_ISSUES"
}

# One job; prints its conclusion (success, failure, skipped). The log is <wdir>/<job>.log.
run_job() {
  local file="$1" wf="$2" job="$3" event="$4" wdir="$5" needs="$6" sha="$7" ref="$8" base_ref="$9" head_ref="${10}"
  local jdef ctx="$wdir/$job.ctx.json" log="$wdir/$job.log" cond ok st nsteps k step id ws
  jdef="$(jq -c --arg j "$job" '.jobs[$j]' <<<"$wf")"
  : >"$log"
  ws="$wdir/$job.ws"; mkdir -p "$ws" "$wdir/$job.tmp"
  # needs: success() is true only when every needed job succeeded (a skipped need skips the job).
  ok="$(jq -r --argjson n "$needs" '[(.needs // [] | if type == "string" then [.] else . end)[] | $n[.].result] | all(. == "success")' <<<"$jdef")"
  jq --argjson n "$needs" --arg t "$wdir/$job.tmp" '.needs = $n | .runner.temp = $t' "$wdir/ctx0.json" >"$ctx"
  st="$(jq -cn --argjson ok "$ok" '{success: $ok, failure: ($ok | not)}')"
  cond="$(jq -r 'if has("if") then .if | tostring else "" end' <<<"$jdef")"
  if [ -n "$cond" ]; then
    local pre=""; [ "$(xjq "$ctx" 'has_status($c)' --arg c "$cond")" = true ] || pre="success() && "
    [ "$(jq -c --argjson s "$st" '{ctx: ., status: $s}' "$ctx" | jq -r -L "$SIM_LIB" --arg c "$pre($cond)" 'include "expr"; ev($c) | truthy')" = true ] ||
      { echo "job skipped: if: $cond" >>"$log"; echo skipped; return; }
  elif [ "$ok" != true ]; then echo "job skipped: a needed job did not succeed" >>"$log"; echo skipped; return
  fi
  if jq -e 'has("uses")' <<<"$jdef" >/dev/null; then
    run_call "$file" "$job" "$jdef" "$ctx" "$event" "$sha" "$ref" "$base_ref" "$head_ref"; return
  fi
  # environment: (specs/factory-step3-v1 TB10): a job runs only from a ref its deployment branch policy
  # allows, and only then sees the environment's secrets (SIM_ENVIRONMENTS).
  local envname
  envname="$(jq -r '.environment // "" | if type == "object" then .name else . end' <<<"$jdef")"
  if [ -n "$envname" ]; then
    local edef; edef="$(jq -c --arg n "$envname" '.[$n] // {branches: null, secrets: {}}' <<<"${SIM_ENVIRONMENTS:-"{}"}")"
    if ! jq -e --arg r "$ref" '.branches == null or ($r | startswith("refs/heads/") and (ltrimstr("refs/heads/") | IN($r_b[]?)))'          --argjson r_b "$(jq -c '.branches // []' <<<"$edef")" <<<"$edef" >/dev/null; then
      echo "job failed: $ref is not allowed to deploy to $envname due to environment protection rules" >>"$log"; echo failure; return
    fi
    jq --argjson s "$(jq -c '.secrets // {}' <<<"$edef")" '.secrets += $s' "$ctx" >"$ctx.n" && mv "$ctx.n" "$ctx"
    echo "environment $envname: $ref may deploy; its secrets are in the context" >>"$log"
  fi
  # env: workflow env, then job env, each value an expression template.
  local envj
  envj="$(jq -c --argjson w "$(jq -c '.env // {}' <<<"$wf")" '$w + (.env // {})' <<<"$jdef")"
  envj="$(jq -c --argjson e "$envj" '{ctx: ., status: {success: true, failure: false}}' "$ctx" |
          jq -c -L "$SIM_LIB" --argjson e "$envj" 'include "expr"; . as $in | $e | map_values(tostring as $v | $in | tmpl($v))')" ||
    drv_die "$file/$job: bad env expression"
  jq --argjson e "$envj" '.env = $e' "$ctx" >"$ctx.n" && mv "$ctx.n" "$ctx"
  local shell_default
  shell_default="$(jq -r --argjson w "$(jq -c '.defaults.run.shell // null' <<<"$wf")" '.defaults.run.shell // $w // ""' <<<"$jdef")"
  : >"$wdir/$job.out"; : >"$wdir/$job.summary"
  nsteps="$(jq '.steps | length' <<<"$jdef")"
  local failed=0 refs0
  refs0="$(git -C "$ORIGIN" for-each-ref --format='%(refname) %(objectname)' refs/heads/)"
  for ((k = 0; k < nsteps; k++)); do
    step="$(jq -c --argjson k "$k" '.steps[$k]' <<<"$jdef")"
    id="$(jq -r --argjson k "$k" '.id // "__step\($k)"' <<<"$step")"
    st="$(jq -cn --argjson f "$failed" '{success: ($f == 0), failure: ($f == 1)}')"
    cond="$(jq -r 'if has("if") then .if | tostring else "" end' <<<"$step")"
    local run_it=true
    if [ -n "$cond" ]; then
      local pre=""; [ "$(xjq "$ctx" 'has_status($c)' --arg c "$cond")" = true ] || pre="success() && "
      run_it="$(jq -c --argjson s "$st" '{ctx: ., status: $s}' "$ctx" | jq -r -L "$SIM_LIB" --arg c "$pre($cond)" 'include "expr"; ev($c) | truthy')" ||
        drv_die "$file/$job step $k: bad if: $cond"
    elif [ "$failed" = 1 ]; then run_it=false
    fi
    if [ "$run_it" != true ]; then
      printf '## step %s (%s): skipped\n' "$k" "$(jq -r '.name // .uses // "run"' <<<"$step")" >>"$log"
      jq --arg id "$id" '.steps[$id] = {outputs: {}, outcome: "skipped", conclusion: "skipped"}' "$ctx" >"$ctx.n" && mv "$ctx.n" "$ctx"
      continue
    fi
    local senv rc=0
    senv="$(jq -c --argjson s "$st" '{ctx: ., status: $s}' "$ctx" |
            jq -c -L "$SIM_LIB" --argjson st "$step" 'include "expr"; . as $in | .ctx.env + (($st.env // {}) | map_values(tostring as $v | $in | tmpl($v)))')" ||
      drv_die "$file/$job step $k: bad env expression"
    : >"$wdir/$job.out"
    printf '## step %s (%s)\n' "$k" "$(jq -r '.name // .uses // "run"' <<<"$step")" >>"$log"
    if jq -e 'has("uses")' <<<"$step" >/dev/null; then
      run_uses "$step" "$ctx" "$ws" "$event" "$sha" "$ref" "$wdir/$job.out" >>"$log" 2>&1 || rc=$?
    else
      local script="$wdir/$job.step$k.sh" sh
      jq -c '{ctx: ., status: {success: true, failure: false}}' "$ctx" |
        jq -r -L "$SIM_LIB" --arg r "$(jq -r .run <<<"$step")" 'include "expr"; tmpl($r)' >"$script" ||
        drv_die "$file/$job step $k: bad run: template"
      sh="$(jq -r --arg d "$shell_default" '.shell // $d' <<<"$step")"
      local -a shcmd
      case "$sh" in
        "") shcmd=(bash -e) ;;
        bash) shcmd=(bash --noprofile --norc -eo pipefail) ;;
        *) drv_die "$file/$job: shell $sh is not simulated" ;;
      esac
      local -a envargs=()
      while IFS= read -r kv; do envargs+=("$kv"); done < <(jq -r 'to_entries[] | "\(.key)=\(.value)"' <<<"$senv")
      ( cd "$ws" && env PATH="$wdir/$job.pipx-bin:$RUNNER_PATH" PIPX_BIN_DIR="$wdir/$job.pipx-bin" HOME="$SIM/runner-home" CI=true GITHUB_ACTIONS=true RUNNER_ENVIRONMENT=github-hosted \
          RUNNER_TEMP="$wdir/$job.tmp" GITHUB_WORKSPACE="$ws" GITHUB_EVENT_PATH="$wdir/event.json" GITHUB_EVENT_NAME="$event" \
          GITHUB_SHA="$sha" GITHUB_REF="$ref" GITHUB_BASE_REF="$base_ref" GITHUB_HEAD_REF="$head_ref" GITHUB_REPOSITORY="$REPO" \
          GITHUB_OUTPUT="$wdir/$job.out" GITHUB_STEP_SUMMARY="$wdir/$job.summary" \
          FAKE_GH_USER=app/github-actions FAKE_GH_BOT=1 "${envargs[@]}" "${shcmd[@]}" "$script" ) >>"$log" 2>&1 || rc=$?
    fi
    local outcome=success
    if [ "$rc" != 0 ]; then
      outcome=failure; printf '## step %s exit %s\n' "$k" "$rc" >>"$log"
      [ "$(jq -r '."continue-on-error" // false' <<<"$step")" = true ] || failed=1
    fi
    local outs
    outs="$(sed -n 's/^\([A-Za-z0-9_-]*\)=\(.*\)$/\1\t\2/p' "$wdir/$job.out" | jq -Rsc 'split("\n")[:-1] | map(split("\t") | {(.[0]): .[1]}) | add // {}')"
    jq --arg id "$id" --argjson o "$outs" --arg c "$outcome" '.steps[$id] = {outputs: $o, outcome: $c, conclusion: $c}' "$ctx" >"$ctx.n" && mv "$ctx.n" "$ctx"
  done
  drv_pushes "$file" "$job" "$ctx" "$refs0"
  if [ "$failed" = 1 ]; then echo failure; else echo success; fi
}

# `uses:` steps the workflows name, emulated; anything else is a driver error.
run_uses() {
  local step="$1" ctx="$2" ws="$3" event="$4" sha="$5" ref="$6" out="$7" uses with
  uses="$(jq -r .uses <<<"$step")"
  with="$(jq -c '{ctx: ., status: {success: true, failure: false}}' "$ctx" |
          jq -c -L "$SIM_LIB" --argjson st "$step" 'include "expr"; . as $in | ($st.with // {}) | map_values(tostring as $v | $in | tmpl($v))')"
  case "$uses" in
    actions/checkout@*)
      local r depth path dir
      r="$(jq -r '.ref // ""' <<<"$with")"; depth="$(jq -r '."fetch-depth" // "1"' <<<"$with")"; path="$(jq -r '.path // ""' <<<"$with")"
      dir="$ws${path:+/$path}"
      # A target dir that is not a git repo has its contents deleted first (actions/checkout v4,
      # 11d5960, src/git-directory-helper.ts:26-31,116-124): a `.base/` the PR head commits is wiped
      # before the base is checked out there.
      if [ -d "$dir" ] && [ ! -d "$dir/.git" ]; then
        echo "Deleting the contents of '$dir'"; find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
      fi
      # With no `ref:`, a branch event checks out its branch by name (`checkout -B <branch>`, not a
      # detached sha); a pull_request (refs/pull/<n>/merge) stays detached.
      local name=""
      if [ -z "$r" ]; then r="$sha"; case "$ref" in refs/heads/*) name="${ref#refs/heads/}" ;; esac; fi
      if [ "$depth" = 0 ]; then
        git clone -q --no-checkout "$ORIGIN" "$dir"
        git -C "$dir" checkout -q --detach "$(git -C "$ORIGIN" rev-parse "$r^{commit}")"
      else
        git init -q "$dir" && git -C "$dir" remote add origin "$ORIGIN"
        git -C "$dir" fetch -q --depth=1 origin "$(git -C "$ORIGIN" rev-parse "$r^{commit}")"
        git -C "$dir" checkout -q --detach FETCH_HEAD
      fi
      [ "$r" = "$sha" ] || ! git -C "$ORIGIN" show-ref -q --verify "refs/heads/$r" || name="$r"
      [ -z "$name" ] || git -C "$dir" checkout -q -B "$name" HEAD
      echo "checkout $r (fetch-depth $depth) at $(git -C "$dir" rev-parse HEAD)" ;;
    actions/setup-node@*|actions/setup-python@*) echo "$uses: the runner's own (no-op in the sim)" ;;
    actions/dependency-review-action@*)
      # Outside pull_request(_target) the action reads base-ref and head-ref and fails without them
      # ("Both a base ref and head ref must be provided", its README: "only used for event types other
      # than pull_request and pull_request_target").
      case "$event" in
        pull_request|pull_request_target) ;;
        *) [ -n "$(jq -r '."base-ref" // ""' <<<"$with")" ] && [ -n "$(jq -r '."head-ref" // ""' <<<"$with")" ] ||
             { echo "dependency-review: Both a base ref and head ref must be provided, either via the \`base_ref\`/\`head_ref\` config options, \`base-ref\`/\`head-ref\` workflow action options, or by running a \`pull_request\`/\`pull_request_target\` workflow."; return 1; } ;;
      esac
      echo "dependency-review: the repo has no dependency manifest; no change reviewed" ;;
    actions/create-github-app-token@*)
      [ "$(jq -r '."private-key" // ""' <<<"$with")" != "" ] || { echo "create-github-app-token: no private key"; return 1; }
      echo "token=ghs_sim_app_token" >>"$out"; echo "minted the App token (sim)" ;;
    *) drv_die "uses: $uses is not emulated" ;;
  esac
}
