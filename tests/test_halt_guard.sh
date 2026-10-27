#!/usr/bin/env bash
# T29 (specs/factory-step3-v1 TB10; docs/adr/0004-halt-two-person-rule.md): factory/bin/halt-guard.sh,
# the kill switch's asymmetry: zero approvals to add factory/HALT, two to remove it.
#   - the gate (CI's `halt-guard` job, pull_request): a PR that adds factory/HALT, edits it or does not
#     touch it passes with no review read; one that deletes it passes only with two distinct approvals
#     by the owners the BASE's CODEOWNERS names for it, on the PR's current head (owners-check.sh
#     --only factory/HALT counts them): one approval, a stale one, the author's own, an owner the head
#     adds to CODEOWNERS, a later CHANGES_REQUESTED all leave it short (exit 2, "approv" on stderr);
#   - --add (halt.yml): only an actor with write access (the owner's admin, a collaborator's write)
#     may halt, a read-only or revoked one is refused (exit 2) and a malformed --actor dies (exit 1),
#     both before anything is fetched or pushed;
#   - --dry-run and the default print result dry-run and push nothing; a HALT already on main is
#     already-halted and pushes nothing;
#   - --apply lands exactly one commit on origin main: parent the old main, tree the old tree plus
#     factory/HALT (actor, time, reason), github-actions[bot] author and committer, subject
#     `halt: stop the line (@<actor>)`, no `Ticket:` trailer;
#   - a moved main: the origin's update hook lands another push between the fetch and the ref update
#     (git's own compare-and-swap refuses the halt), the retry rebuilds on the moved main without force;
#     a main that moves on every attempt gives up after three (exit 1).
# Offline; every repo is a temp dir (origin a local bare repo), gh is the fake.
set -euo pipefail
# shellcheck source=tests/fakes/lib.sh
. "$(dirname "$0")/fakes/lib.sh"
HG="$BIN/halt-guard.sh"
EV="$REPO_ROOT/tests/fixtures/events"
FREPO=Codertocat/Hello-World   # the repository of GitHub's example payloads (PR #2 by Codertocat, OWNER)
NOW=1793102400                 # FACTORY_NOW of the --add cases
BOT='github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>'

st() { jq "$@" "$FAKE_GH_ISSUES" >"$WORLD/s" && mv "$WORLD/s" "$FAKE_GH_ISSUES"; }   # st [jq args] <program>
field() { jq -r "$1" <<<"$OUT"; }
has() { /usr/bin/grep -qF -- "$1" <<<"$ERR"; }
hasnt() { ! /usr/bin/grep -qF -- "$1" <<<"$ERR"; }

# ---------------------------------------------------------------- the gate

# A repo R: NOHALT (README, .github/CODEOWNERS: `*` Codertocat, /factory/ alice, Bob and Codertocat)
# and HALTED on top of it (factory/HALT added), main = HALTED. alice and bob are collaborators.
setup_gate() {
  fakegh_setup
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export FAKE_GH_REPO="$FREPO" GITHUB_REPOSITORY="$FREPO" FACTORY_REPO="$FREPO"
  printf '{"labels":[],"issues":[],"pulls":[],"collaborators":["alice","bob"]}\n' >"$FAKE_GH_ISSUES"
  R="$WORLD/r"
  git init -q -b main "$R"
  git -C "$R" config user.name t; git -C "$R" config user.email t@t.invalid
  mkdir -p "$R/.github"; echo base >"$R/README.md"
  printf '* @Codertocat\n/factory/ @alice @Bob @Codertocat\n' >"$R/.github/CODEOWNERS"
  git -C "$R" add -A; git -C "$R" commit -qm root
  NOHALT="$(git -C "$R" rev-parse HEAD)"
  mkdir -p "$R/factory"; echo 'halted by @alice at 2026-10-27T00:00:00Z: test' >"$R/factory/HALT"
  git -C "$R" add -A; git -C "$R" commit -qm "halt: stop the line (@alice)"
  HALTED="$(git -C "$R" rev-parse HEAD)"
  unset GITHUB_EVENT_NAME GITHUB_EVENT_PATH GH_TOKEN
}
# mkhead <base> <branch> <op>...: a branch from <base> with one commit doing each op (rm: delete
# factory/HALT, add: create it, edit: append to it, readme: append to README, owner: add @carol to the
# /factory/ line of CODEOWNERS); prints its sha and leaves R on main.
mkhead() {
  local base="$1" br="$2" op; shift 2
  git -C "$R" checkout -q -B "$br" "$base"
  for op in "$@"; do
    case "$op" in
      rm) git -C "$R" rm -q factory/HALT ;;
      add) mkdir -p "$R/factory"; echo 'halted by @Codertocat' >"$R/factory/HALT" ;;
      edit) echo 'still halted' >>"$R/factory/HALT" ;;
      readme) echo more >>"$R/README.md" ;;
      owner) sed -i 's|^/factory/ .*|& @carol|' "$R/.github/CODEOWNERS" ;;
    esac
  done
  git -C "$R" add -A; git -C "$R" commit -qm "$*"
  git -C "$R" rev-parse HEAD
  git -C "$R" checkout -q main
}
# pr <base> <head-sha> <head-ref> <reviews>: GitHub's example pull_request payload (PR #2 by Codertocat,
# OWNER) on this world's base and head, and the fake's PR #2 with that head and those reviews.
pr() {
  jq --arg b "$1" --arg h "$2" --arg r "$3" --arg hr "$FREPO" \
    '.pull_request.base.sha = $b | .pull_request.base.ref = "main" | .pull_request.head.sha = $h | .pull_request.head.ref = $r
     | .pull_request.author_association = "OWNER" | .pull_request.head.repo.full_name = $hr' \
    "$EV/pull_request-opened.json" >"$WORLD/event.json"
  st --arg h "$2" --arg r "$3" --argjson rv "$4" \
    '.pulls = [{number: 2, headRefName: $r, headRefOid: $h, state: "OPEN", author: {login: "Codertocat"}, reviews: $rv}]'
  export GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="$WORLD/event.json"
}
# rv <login=STATE[@commit]>...: a reviews array, oldest first (as gh answers it); without @commit the
# fake answers the review on the PR's head.
rv() {
  jq -cn '$ARGS.positional | map(split("=") | (.[1] | split("@")) as $s
          | {author: {login: .[0]}, state: $s[0]} + (if $s[1] then {commit: {oid: $s[1]}} else {} end))' --args "$@"
}
hg() {  # hg: run halt-guard.sh (the gate, no flags, as gates.yml does) in R; OUT (stdout), ERR (stderr), RC
  RC=0
  OUT="$(cd "$R" && "$HG" 2>"$WORLD/err")" || RC=$?
  ERR="$(command cat "$WORLD/err")"
}
reviews_read() { fakegh_calls 'any(.[]; . == "repos/'"$FREPO"'/pulls/2/reviews")'; }

case_no_approval_needed() {
  setup_gate
  local h
  # Adding HALT: no review at all.
  h="$(mkhead "$NOHALT" stop add)"
  pr "$NOHALT" "$h" stop '[]'
  hg
  check "add: exit 0, the JSON (class halt, halt add, pass)" eq "$RC:$OUT" '0:{"pr":2,"class":"halt","halt":"add","result":"pass"}'
  check "  stderr: a halt needs no approval" has "halt-guard: pass: factory/HALT added: a halt needs no approval"
  check "  the base's copy of the gate ran" has "halt-guard: halt gate from $REPO_ROOT on"
  check "  no review was read" eq "$(reviews_read)" 0
  # Editing HALT (the line stays stopped): human class, no review.
  h="$(mkhead "$HALTED" reword edit)"
  pr "$HALTED" "$h" reword '[]'
  hg
  check "edit: exit 0, the JSON (class human, halt edit, pass)" eq "$RC:$OUT" '0:{"pr":2,"class":"human","halt":"edit","result":"pass"}'
  check "  stderr says edited" has "halt-guard: pass: factory/HALT edited: a halt needs no approval"
  check "  no review was read" eq "$(reviews_read)" 0
  # Not touching it, on a halted base and on an unhalted one.
  h="$(mkhead "$HALTED" docs readme)"
  pr "$HALTED" "$h" docs '[]'
  hg
  check "untouched (halted base): exit 0, halt none" eq "$RC:$OUT" '0:{"pr":2,"class":"human","halt":"none","result":"pass"}'
  check "  stderr: not touched" has "halt-guard: pass: factory/HALT is not touched"
  h="$(mkhead "$NOHALT" docs2 readme)"
  pr "$NOHALT" "$h" docs2 '[]'
  hg
  check "untouched (unhalted base): exit 0, halt none" eq "$RC:$(field '[.halt, .result] | join(" ")')" "0:none pass"
  check "  no review was read in any of them" eq "$(reviews_read)" 0
}

case_remove_one_approval() {
  setup_gate
  local h
  h="$(mkhead "$HALTED" unhalt rm)"
  pr "$HALTED" "$h" unhalt "$(rv alice=APPROVED)"
  hg
  check "one owner approval: exit 2" eq "$RC" 2
  check "  stdout: halt remove, approvals [alice], the base's owners, short" \
    eq "$OUT" '{"pr":2,"class":"halt","halt":"remove","approvals":["alice"],"owners":["@alice","@Bob","@Codertocat"],"result":"short"}'
  check "  stderr says approv (the sim's judge greps it)" has "approv"
  check "  stderr: the FAIL line with the count" \
    has "halt-guard: FAIL: removing factory/HALT needs two distinct approvals by its code owners on the PR head; it has 1"
  check "  stderr: owners-check names the path, owners and head" \
    has "owners-check: SHORT: factory/HALT needs 2 distinct approvals by its code owners (@alice @Bob @Codertocat) on the PR head ${h:0:12}; it has 1 (alice)"
  check "  the reviews were read once" eq "$(reviews_read)" 1
  # No review at all.
  pr "$HALTED" "$h" unhalt '[]'
  hg
  check "no approval: exit 2, short, approvals []" eq "$RC:$(field '[.result, (.approvals | tojson)] | join(" ")')" "2:short []"
  check "  stderr: it has 0" has "it has 0"
  # One owner approving twice is still one.
  pr "$HALTED" "$h" unhalt "$(rv alice=APPROVED alice=APPROVED)"
  hg
  check "the same owner twice: exit 2, approvals [alice]" eq "$RC:$(field '.approvals | join(",")')" 2:alice
}

case_remove_two_approvals() {
  setup_gate
  local h
  h="$(mkhead "$HALTED" unhalt rm)"
  # bob's login is lower case, CODEOWNERS says @Bob: GitHub logins are case-insensitive.
  pr "$HALTED" "$h" unhalt "$(rv alice=APPROVED bob=APPROVED)"
  hg
  check "two distinct owner approvals on the head: exit 0" eq "$RC" 0
  check "  stdout: approvals [alice, bob], pass" \
    eq "$OUT" '{"pr":2,"class":"halt","halt":"remove","approvals":["alice","bob"],"owners":["@alice","@Bob","@Codertocat"],"result":"pass"}'
  check "  stderr: pass with two approvals" has "halt-guard: pass: removing factory/HALT has two distinct code-owner approvals"
  # An owner named by a factory/HALT line of CODEOWNERS (the last match wins), not /factory/.
  git -C "$R" checkout -q main
  printf '/factory/HALT @carol @dave\n' >>"$R/.github/CODEOWNERS"
  git -C "$R" commit -qam "own HALT apart"
  local base; base="$(git -C "$R" rev-parse HEAD)"
  h="$(mkhead "$base" unhalt2 rm)"
  pr "$base" "$h" unhalt2 "$(rv carol=APPROVED dave=APPROVED)"
  hg
  check "the last matching line's owners (factory/HALT carol, dave): pass" \
    eq "$RC:$(field '[.result, (.owners | join(" ")), (.approvals | join(","))] | join(" | ")')" "0:pass | @carol @dave | carol,dave"
  pr "$base" "$h" unhalt2 "$(rv alice=APPROVED bob=APPROVED)"
  hg
  check "  the /factory/ owners no longer count for it: short, approvals []" \
    eq "$RC:$(field '[.result, (.approvals | tojson)] | join(" ")')" "2:short []"
}

case_remove_stale_or_author() {
  setup_gate
  local h1 h
  h1="$(mkhead "$HALTED" unhalt rm)"
  # A push after bob's approval: the PR head is now h, bob approved h1.
  git -C "$R" checkout -q unhalt; echo more >>"$R/README.md"; git -C "$R" commit -qam "a push after the review"
  h="$(git -C "$R" rev-parse HEAD)"; git -C "$R" checkout -q main
  pr "$HALTED" "$h" unhalt "$(rv "bob=APPROVED@$h1" alice=APPROVED)"
  hg
  check "two approvals, one on an older head: exit 2, approvals [alice], short" \
    eq "$RC:$(field '[(.approvals | join(",")), .result] | join(" ")')" "2:alice short"
  check "  stderr says approv" has "approv"
  pr "$HALTED" "$h" unhalt "$(rv "bob=APPROVED@$h1" "alice=APPROVED@$h1")"
  hg
  check "both on the older head: exit 2, approvals []" eq "$RC:$(field '.approvals | tojson')" "2:[]"
  # bob re-approves on the current head: two again.
  pr "$HALTED" "$h" unhalt "$(rv "bob=APPROVED@$h1" alice=APPROVED "bob=APPROVED@$h")"
  hg
  check "a fresh re-approval on the head counts: exit 0, pass" eq "$RC:$(field '[(.approvals | join(",")), .result] | join(" ")')" "0:alice,bob pass"
  # The author (Codertocat, an owner of /factory/) approving their own removal does not count.
  pr "$HALTED" "$h" unhalt "$(rv Codertocat=APPROVED alice=APPROVED)"
  hg
  check "the author's own approval does not count: exit 2, approvals [alice]" \
    eq "$RC:$(field '[(.approvals | join(",")), .result] | join(" ")')" "2:alice short"
  check "  the author is still listed as an owner" eq "$(field '.owners | index("@Codertocat") != null')" true
  # A later CHANGES_REQUESTED replaces an approval.
  pr "$HALTED" "$h" unhalt "$(rv alice=APPROVED bob=APPROVED bob=CHANGES_REQUESTED)"
  hg
  check "approved then changes requested: exit 2, approvals [alice]" eq "$RC:$(field '.approvals | join(",")')" 2:alice
  # A non-owner's approval (a collaborator outside CODEOWNERS) does not count either.
  pr "$HALTED" "$h" unhalt "$(rv alice=APPROVED eve=APPROVED)"
  hg
  check "a non-owner's approval: exit 2, approvals [alice]" eq "$RC:$(field '.approvals | join(",")')" 2:alice
}

case_remove_owner_from_head() {
  setup_gate
  local h
  # The head deletes HALT and adds @carol to /factory/ in its own CODEOWNERS: the base's file counts.
  h="$(mkhead "$HALTED" takeover rm owner)"
  pr "$HALTED" "$h" takeover "$(rv carol=APPROVED alice=APPROVED)"
  hg
  check "an owner the head adds does not count: exit 2, short" eq "$RC:$(field .result)" 2:short
  check "  class human (the diff is more than HALT), halt remove" eq "$(field '[.class, .halt] | join(" ")')" "human remove"
  check "  the owners are the base's" eq "$(field '.owners | join(" ")')" "@alice @Bob @Codertocat"
  check "  approvals [alice]" eq "$(field '.approvals | join(",")')" alice
  check "  stderr says approv" has "approv"
}

# ---------------------------------------------------------------- --add (halt.yml)

# The fakes' origin (a local bare repo: main holds README.md) cloned to C; repo test/repo, owner
# `test` (admin), collaborators dev and gone (gone revoked). OLD: origin main before the case.
setup_add() {
  fakegh_setup
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 FACTORY_NOW="$NOW"
  st '.collaborators = ["dev", "gone"] | .removed_collaborators = ["gone"]'
  C="$WORLD/c"
  git clone -q -b main "$FAKE_GH_GIT" "$C"
  OLD="$(fakegh_ref refs/heads/main)"
  BEFORE="$(refs)"
}
refs() { git -C "$FAKE_GH_GIT" for-each-ref --format='%(refname) %(objectname)'; }
add() {  # add [flags]: run halt-guard.sh --add in C; OUT, ERR, RC
  RC=0
  OUT="$(cd "$C" && "$HG" --add "$@" 2>"$WORLD/err")" || RC=$?
  ERR="$(command cat "$WORLD/err")"
}
perm_reads() { fakegh_calls '.[1] | test("/collaborators/.*/permission$")'; }
# halted_ok <name> <actor> <parent> <reason>: origin main is OUT's sha, one commit on <parent> adding
# exactly factory/HALT with the actor, time and reason, in the bot's name, with no Ticket: trailer.
# The reason is compared without trailing blanks: `tr '\n' ' ' <<<"$reason"` turns the here-string's
# own newline into a trailing space (halt-guard.sh, the reason line), which this test does not pin.
halted_ok() {
  local new; new="$(fakegh_ref refs/heads/main)"
  check "$1: stdout: halted, sha = the new origin main, main = the old" \
    eq "$OUT" "{\"actor\":\"$2\",\"result\":\"halted\",\"sha\":\"$new\",\"main\":\"$3\"}"
  check "  exactly one commit, whose only parent is the old main" eq "$(git -C "$FAKE_GH_GIT" log --format=%P "$3..$new")" "$3"
  check "  its tree is the old tree plus factory/HALT" eq "$(git -C "$FAKE_GH_GIT" diff --name-status "$3" "$new")" $'A\tfactory/HALT'
  check "  every other entry is the old tree's" \
    eq "$(git -C "$FAKE_GH_GIT" ls-tree -r "$new" | /usr/bin/grep -v $'\tfactory/HALT$')" "$(git -C "$FAKE_GH_GIT" ls-tree -r "$3")"
  check "  author and committer github-actions[bot]" \
    eq "$(git -C "$FAKE_GH_GIT" show -s --format='%an <%ae>|%cn <%ce>' "$new")" "$BOT|$BOT"
  check "  subject: halt: stop the line (@$2)" eq "$(git -C "$FAKE_GH_GIT" show -s --format=%s "$new")" "halt: stop the line (@$2)"
  check "  the body is the reason" eq "$(git -C "$FAKE_GH_GIT" show -s --format=%b "$new" | sed 's/ *$//')" "$4"
  check "  no Ticket: trailer" eq "$(git -C "$FAKE_GH_GIT" show -s --format='%(trailers:key=Ticket)' "$new")" ""
  check "  factory/HALT: halted by @$2 at the time: the reason" \
    eq "$(git -C "$FAKE_GH_GIT" show "$new:factory/HALT" | sed 's/ *$//')" "halted by @$2 at $(jq -nr "$NOW | todate"): $4"
  check "  mode 100644" eq "$(git -C "$FAKE_GH_GIT" ls-tree "$new" factory/HALT | cut -d' ' -f1)" 100644
}

case_permission() {
  setup_add
  add --actor stranger --reason "why not" --apply
  check "a read-only actor: exit 2, no stdout" eq "$RC:$OUT" 2:
  check "  stderr: write access needed" \
    has "halt-guard: @stranger has read access to test/repo: only a collaborator with write access may halt the factory"
  check "  nothing pushed (origin refs unchanged)" eq "$(refs)" "$BEFORE"
  check "  the permission was read once" eq "$(perm_reads)" 1
  add --actor gone --apply
  check "a revoked collaborator (read): exit 2, nothing pushed" eq "$RC:$OUT:$(refs)" "2::$BEFORE"
  check "  stderr names the access" has "@gone has read access"
  # The owner (admin) halts.
  add --actor test --reason "owner stops it" --apply
  check "the owner (admin): exit 0" eq "$RC" 0
  halted_ok "admin" test "$OLD" "owner stops it"
  # A collaborator (write) halts too, on a main without HALT again.
  git -C "$FAKE_GH_GIT" update-ref refs/heads/main "$OLD"
  add --actor dev --reason "collaborator stops it" --apply
  check "a collaborator (write): exit 0" eq "$RC" 0
  halted_ok "write" dev "$OLD" "collaborator stops it"
  check "  the gh calls were permission reads only" eq "$(fakegh_calls '.[1] | test("/permission$") | not')" 0
}

case_bad_actor() {
  setup_add
  local a
  for a in "" "-x" "two words" "a/b" "x@y" "$(printf 'a%.0s' {1..40})" "dev;rm"; do
    add --actor "$a" --apply
    check "--actor '$a': exit 1, no stdout, nothing pushed" eq "$RC:$OUT:$(refs)" "1::$BEFORE"
    check "  stderr: needs a GitHub login" has "halt-guard: --actor needs a GitHub login"
  done
  add --apply
  check "no --actor at all: exit 1" eq "$RC:$OUT" 1:
  check "  stderr: needs a GitHub login" has "--actor needs a GitHub login, got ''"
  add --actor dev --force
  check "an unknown flag: exit 1" eq "$RC:$OUT" 1:
  check "  stderr names it" has "halt-guard: unknown argument: --force"
  check "no permission was read for any of them" eq "$(perm_reads)" 0
  # A bot login is a login.
  add --actor 'renovate[bot]'
  check "a [bot] login is well-formed (read access: refused, exit 2)" eq "$RC" 2
}

case_dry_run() {
  setup_add
  add --actor dev --reason "line stops" --dry-run
  check "--dry-run: exit 0, result dry-run, sha null, main the old" \
    eq "$RC:$OUT" "0:{\"actor\":\"dev\",\"result\":\"dry-run\",\"sha\":null,\"main\":\"$OLD\"}"
  check "  stderr: the plan" \
    has "halt-guard: dry run: would commit factory/HALT (halted by @dev at $(jq -nr "$NOW | todate"): line stops"
  check "  onto the old main" has "onto main ${OLD:0:12} and push it"
  check "  nothing pushed" eq "$(refs)" "$BEFORE"
  add --actor dev --reason "line stops"
  check "neither flag (the default): exit 0, dry-run, nothing pushed" \
    eq "$RC:$(field .result):$(refs)" "0:dry-run:$BEFORE"
  add --actor dev --apply --dry-run
  check "--apply then --dry-run: the last wins, dry-run" eq "$RC:$(field .result):$(refs)" "0:dry-run:$BEFORE"
  add --actor stranger --dry-run
  check "a read-only actor is refused in a dry run too (exit 2)" eq "$RC:$OUT" 2:
  add --actor dev
  check "no reason: the plan says no reason given" has "(halted by @dev at $(jq -nr "$NOW | todate"): no reason given"
}

case_apply() {
  setup_add
  add --actor dev --reason $'the gates are red\nsince 09:00' --apply
  check "--apply: exit 0" eq "$RC" 0
  halted_ok "apply" dev "$OLD" "the gates are red since 09:00"
  check "  only main moved (nodes untouched, no new ref)" \
    eq "$(refs | /usr/bin/grep -v '^refs/heads/main ')" "$(/usr/bin/grep -v '^refs/heads/main ' <<<"$BEFORE")"
  check "  stderr: halted" has "halt-guard: halted: factory/HALT committed as $(field '.sha[0:12]') on main (by @dev)"
  check "  the clone's own main and work tree untouched" \
    eq "$(git -C "$C" rev-parse refs/heads/main):$(git -C "$C" status --porcelain)" "$OLD:"
  # No reason: the file and the body say so; a long reason is cut at 200 characters.
  git -C "$FAKE_GH_GIT" update-ref refs/heads/main "$OLD"
  add --actor dev --apply
  check "no --reason: exit 0" eq "$RC" 0
  check "  factory/HALT says no reason given" \
    eq "$(git -C "$FAKE_GH_GIT" show refs/heads/main:factory/HALT | sed 's/ *$//')" "halted by @dev at $(jq -nr "$NOW | todate"): no reason given"
  git -C "$FAKE_GH_GIT" update-ref refs/heads/main "$OLD"
  add --actor dev --reason "$(printf 'x%.0s' {1..300})" --apply
  check "a 300-character reason is cut to 200" \
    eq "$(git -C "$FAKE_GH_GIT" show refs/heads/main:factory/HALT | sed 's/.*: //' | tr -d '\n' | wc -c | tr -d ' ')" 200
}

case_already_halted() {
  setup_add
  local blob sub tree h
  # Another halt already on origin main.
  blob="$(printf 'halted by @test\n' | git -C "$FAKE_GH_GIT" hash-object -w --stdin)"
  sub="$(printf '100644 blob %s\tHALT\n' "$blob" | git -C "$FAKE_GH_GIT" mktree)"
  tree="$({ git -C "$FAKE_GH_GIT" ls-tree "$OLD"; printf '040000 tree %s\tfactory\n' "$sub"; } | git -C "$FAKE_GH_GIT" mktree)"
  h="$(_fakegh_commit "$tree" 1761300100 'halt: stop the line (@test)' "$OLD")"
  git -C "$FAKE_GH_GIT" update-ref refs/heads/main "$h"
  BEFORE="$(refs)"
  add --actor dev --reason again --apply
  check "HALT already on main: exit 0, already-halted, sha null, main its commit" \
    eq "$RC:$OUT" "0:{\"actor\":\"dev\",\"result\":\"already-halted\",\"sha\":null,\"main\":\"$h\"}"
  check "  stderr: nothing to add" has "halt-guard: factory/HALT is already on main (${h:0:12}): nothing to add"
  check "  nothing pushed" eq "$(refs)" "$BEFORE"
  add --actor dev --dry-run
  check "the same in a dry run" eq "$RC:$(field .result):$(refs)" "0:already-halted:$BEFORE"
}

# race <n>: an update hook in the origin that, the first <n> times main is pushed, lands another
# commit on main (a file moved-<k>.txt) after the pusher fetched and before its ref update, so git's
# compare-and-swap refuses the push; each moved commit is appended to $WORLD/moved. The origin also
# refuses any non-fast-forward, so a forced push could not land either.
race() {
  echo "$1" >"$WORLD/moves"; : >"$WORLD/moved"
  git -C "$FAKE_GH_GIT" config receive.denyNonFastForwards true
  command cat >"$FAKE_GH_GIT/hooks/update" <<EOF
#!/usr/bin/env bash
set -eu
[ "\$1" = refs/heads/main ] || exit 0
left="\$(cat '$WORLD/moves')"
[ "\$left" -gt 0 ] || exit 0
echo \$((left - 1)) >'$WORLD/moves'
cur="\$(git rev-parse refs/heads/main)"
blob="\$(printf 'another push %s\n' "\$left" | git hash-object -w --stdin)"
tree="\$({ git ls-tree "\$cur"; printf '100644 blob %s\tmoved-%s.txt\n' "\$blob" "\$left"; } | git mktree)"
new="\$(GIT_AUTHOR_NAME=other GIT_AUTHOR_EMAIL=other@fake GIT_COMMITTER_NAME=other GIT_COMMITTER_EMAIL=other@fake \
       git commit-tree "\$tree" -p "\$cur" -m "another push lands first (\$left)")"
git update-ref refs/heads/main "\$new" "\$cur"
echo "\$new" >>'$WORLD/moved'
EOF
  chmod +x "$FAKE_GH_GIT/hooks/update"
}

case_moved_main() {
  setup_add
  local moved new
  race 1
  add --actor dev --reason "red" --apply
  moved="$(command cat "$WORLD/moved")"; new="$(fakegh_ref refs/heads/main)"
  check "main moved once under the push: exit 0" eq "$RC" 0
  check "  the race happened (one moved commit, on the old main)" \
    eq "$(wc -l <"$WORLD/moved" | tr -d ' '):$(git -C "$FAKE_GH_GIT" log --format=%P -n1 "$moved")" "1:$OLD"
  check "  stderr: the first push was refused, rebuilding" \
    has "(attempt 1 of 3): main moved, rebuilding"
  halted_ok "retry" dev "$moved" red
  check "  the moved commit stays in main's history (no force)" \
    eq "$(git -C "$FAKE_GH_GIT" log --format=%H "$OLD..$new" | tr '\n' ' ')" "$new $moved "
  check "  its file is still on main" eq "$(git -C "$FAKE_GH_GIT" show "$new:moved-1.txt")" "another push 1"
}

case_moved_main_twice() {
  setup_add
  race 2
  add --actor dev --apply
  check "main moved twice: exit 0, halted on the second moved commit" \
    eq "$RC:$(field .result):$(field .main)" "0:halted:$(tail -n1 "$WORLD/moved")"
  check "  stderr: attempt 2 refused too" has "(attempt 2 of 3): main moved, rebuilding"
  check "  main is HALT on both moves on the old main" \
    eq "$(git -C "$FAKE_GH_GIT" rev-list --count "$OLD..refs/heads/main")" 3
}

case_main_keeps_moving() {
  setup_add
  race 3
  add --actor dev --apply
  check "main moved on every attempt: exit 1, no stdout" eq "$RC:$OUT" 1:
  check "  stderr: gave up after 3" has "halt-guard: main kept moving: factory/HALT was not pushed after 3 attempts; run halt.yml again"
  check "  three attempts were refused" eq "$(/usr/bin/grep -c 'main moved, rebuilding' <<<"$ERR")" 3
  check "  main is the third moved commit, no HALT on it" \
    eq "$(fakegh_ref refs/heads/main):$(git -C "$FAKE_GH_GIT" ls-tree refs/heads/main factory/HALT)" "$(tail -n1 "$WORLD/moved"):"
}

for c in no-approval-needed remove-one-approval remove-two-approvals remove-stale-or-author remove-owner-from-head \
         permission bad-actor dry-run apply already-halted moved-main moved-main-twice main-keeps-moving; do
  run_case "$c"
done
[ "$FAILED" = 0 ]
