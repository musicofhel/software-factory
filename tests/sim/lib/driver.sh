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
#       Each job's `run:` steps see PATH = <job>.pipx-bin:RUNNER_PATH and PIPX_BIN_DIR = that dir,
#       fresh per job (GitHub: PIPX_BIN_DIR=/opt/pipx_bin on PATH, one VM per job).
#       Appends one JSON line per job to $SIM/jobs.jsonl: {workflow, job, event, conclusion, log}.
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
     elif .event == "pull_request" then (.payload.action | IN("opened", "synchronize", "reopened"))
     else true end)
    and (if .event == "pull_request" then filt($cfg; "branches"; [.payload.pull_request.base.ref])
         elif .event == "push" then filt($cfg; "branches"; [.payload.ref | sub("^refs/heads/"; "")])
         else true end)
    and (if .event == "pull_request" or .event == "push" then
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

drive() {
  local event="$1" evfile="$2" wsha="$3" only="${4:-}"
  local all n i file wf payload files="[]" sha ref base_ref="" head_ref="" head_sha
  payload="$(jq -c . "$evfile")"
  case "$event" in
    pull_request)
      local pn; pn="$(jq -r .number <<<"$payload")"
      sha="$(git -C "$ORIGIN" rev-parse "refs/pull/$pn/merge")" || drv_die "no refs/pull/$pn/merge"
      ref="refs/pull/$pn/merge"; base_ref="$(jq -r .pull_request.base.ref <<<"$payload")"
      head_ref="$(jq -r .pull_request.head.ref <<<"$payload")"; head_sha="$(jq -r .pull_request.head.sha <<<"$payload")"
      files="$(git -C "$ORIGIN" diff --name-only "$(jq -r .pull_request.base.sha <<<"$payload")...$head_sha" | jq -Rsc 'split("\n")[:-1]')" ;;
    merge_group)
      sha="$(jq -r .merge_group.head_sha <<<"$payload")"; ref="$(jq -r .merge_group.head_ref <<<"$payload")"; head_sha="$sha" ;;
    push)
      sha="$(jq -r .after <<<"$payload")"; ref="$(jq -r .ref <<<"$payload")"; head_sha="$sha"
      files="$(git -C "$ORIGIN" diff --name-only "$(jq -r .before <<<"$payload")" "$sha" | jq -Rsc 'split("\n")[:-1]')" ;;
    schedule|issues|workflow_dispatch)
      sha="$(git -C "$ORIGIN" rev-parse refs/heads/main)"; ref=refs/heads/main; head_sha="$sha" ;;
    *) drv_die "event $event is not simulated" ;;
  esac
  all="$(wf_all "$wsha")"
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
    run_workflow "$file" "$wf" "$event" "$payload" "$sha" "$ref" "$base_ref" "$head_ref" "$head_sha"
  done
}

run_workflow() {
  local file="$1" wf="$2" event="$3" payload="$4" sha="$5" ref="$6" base_ref="$7" head_ref="$8" head_sha="$9"
  local wdir job needs="{}" res
  wdir="$(mktemp -d "$SIM/run.XXXXXX")"
  printf '%s\n' "$payload" >"$wdir/event.json"
  jq -n --arg e "$event" --argjson p "$payload" --arg sha "$sha" --arg ref "$ref" --arg r "$REPO" \
     --arg br "$base_ref" --arg hr "$head_ref" --argjson vars "$SIM_VARS" --argjson sec "$SIM_SECRETS" --argjson wf "$wf" '
    {github: {event_name: $e, event: $p, sha: $sha, ref: $ref, repository: $r, token: "ghs_sim_github_token",
              base_ref: $br, head_ref: $hr, workflow: ($wf.name // "")},
     env: {}, vars: $vars, secrets: ($sec + {GITHUB_TOKEN: "ghs_sim_github_token"}), inputs: {}, steps: {}, needs: {},
     job: {}, runner: {os: "Linux", temp: ""}, matrix: {}}' >"$wdir/ctx0.json"
  while IFS= read -r job; do
    res="$(run_job "$file" "$wf" "$job" "$event" "$wdir" "$needs" "$sha" "$ref" "$base_ref" "$head_ref")"
    needs="$(jq -c --arg j "$job" --arg r "$res" '.[$j] = {result: $r, outputs: {}}' <<<"$needs")"
    jq -cn --arg w "$file" --arg j "$job" --arg e "$event" --arg c "$res" --arg h "$head_sha" --arg l "$wdir/$job.log" \
      '{workflow: $w, job: $j, event: $e, conclusion: $c, head_sha: $h, log: $l}' >>"$SIM/jobs.jsonl"
    gh_state '.checks = ((.checks // []) + [{name: $j, workflow: $w, event: $e, head_sha: $h, conclusion: $c}])' \
      --arg j "$job" --arg w "$file" --arg e "$event" --arg h "$head_sha" --arg c "$res"
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
  local failed=0
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
  if [ "$failed" = 1 ]; then echo failure; else echo success; fi
}

# `uses:` steps the workflows name, emulated; anything else is a driver error.
run_uses() {
  local step="$1" ctx="$2" ws="$3" event="$4" sha="$5" ref="$6" out="$7" uses with
  uses="$(jq -r .uses <<<"$step")"
  with="$(jq -c '{ctx: ., status: {success: true, failure: false}}' "$ctx" |
          jq -c -L "$SIM_LIB" --argjson st "$step" 'include "expr"; . as $in | ($st.with // {}) | map_values(tostring as $v | $in | tmpl($v))')"
  case "$uses" in
    actions/checkout@v4)
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
    actions/setup-node@v4|actions/setup-python@v5) echo "$uses: the runner's own (no-op in the sim)" ;;
    actions/dependency-review-action@v4) echo "dependency-review: the repo has no dependency manifest; no change reviewed" ;;
    actions/create-github-app-token@*)
      [ "$(jq -r '."private-key" // ""' <<<"$with")" != "" ] || { echo "create-github-app-token: no private key"; return 1; }
      echo "token=ghs_sim_app_token" >>"$out"; echo "minted the App token (sim)" ;;
    *) drv_die "uses: $uses is not emulated" ;;
  esac
}
