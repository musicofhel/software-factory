#!/usr/bin/env bash
# T10 acceptance 1: factory/bin/revoke-collaborator.sh against the fake gh, offline. The dry run
# calls nothing and prints the call; --apply makes exactly one DELETE; a CODEOWNERS owner (and the
# repo's owner, and a non-login) is refused with exit 2 before any call.
set -euo pipefail
# shellcheck source=tests/fakes/lib.sh
. "$(dirname "$0")/fakes/lib.sh"

REVOKE="$BIN/revoke-collaborator.sh"
# The collaborators slice of the GitHub API, as a shim in front of tests/fakes/gh (the fake is not
# T10's to edit; every other call passes through). State: $WORLD/collaborators.json, a list of logins.
#   GET    repos/<FAKE_GH_REPO>/collaborators            [{login}]
#   DELETE repos/<FAKE_GH_REPO>/collaborators/<login>    no body; removes the login case-blind.
#          GitHub's answer for a login that is not a collaborator is not modelled (204 here too).
# Logged to FAKE_GH_LOG like the fake; FAKE_GH_FAIL injects an HTTP 500; another repo is 404.
collab_shim() {
  mkdir -p "$WORLD/shim"
  command cat >"$WORLD/shim/gh" <<SHIM
#!/usr/bin/env bash
set -euo pipefail
[ "\${1:-}" = api ] || exec "$FAKES_DIR/gh" "\$@"
path="" method=GET
for ((i = 2; i <= \$#; i++)); do
  a="\${!i}"
  case "\$a" in -X) i=\$((i + 1)); method="\${!i}" ;; -*) ;; *) path="\${a#/}" ;; esac
done
case "\$path" in repos/*/collaborators|repos/*/collaborators/*) ;; *) exec "$FAKES_DIR/gh" "\$@" ;; esac
for a in "\$@"; do jq -n --arg a "\$a" '\$a'; done | jq -sc . >>"\$FAKE_GH_LOG"
if [ -n "\${FAKE_GH_FAIL:-}" ] && [[ "\$*" =~ \$FAKE_GH_FAIL ]]; then echo "gh: Server Error (injected) (HTTP 500)" >&2; exit 1; fi
[[ "\$path" == "repos/\$FAKE_GH_REPO/collaborators"* ]] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
db="$WORLD/collaborators.json"
case "\$method \${path#"repos/\$FAKE_GH_REPO/collaborators"}" in
  "GET ") jq -c 'map({login: .})' "\$db" ;;
  "DELETE /"*) jq -c --arg l "\${path##*/}" 'map(select(ascii_downcase != (\$l | ascii_downcase)))' "\$db" >"\$db.tmp"; mv "\$db.tmp" "\$db" ;;
  *) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
esac
SHIM
  chmod +x "$WORLD/shim/gh"
  export PATH="$WORLD/shim:$PATH"
}
rv_setup() {  # a fresh world: collaborators bob, carol, Dave-X and the code owner; a CODEOWNERS fixture
  fakegh_setup
  collab_shim
  echo '["bob", "carol", "Dave-X", "owner1"]' >"$WORLD/collaborators.json"
  CO="$WORLD/CODEOWNERS"
  printf '%s\n' '# comment naming @carol is not an owner' \
    'factory/**   @Owner1 @org/desk' 'docs/*.md    someone@example.com  # @bob in a trailing comment' \
    '*.sh @dave-x' >"$CO"
}
rv() {  # rv <args>: sets RC, OUT, ERR
  RC=0
  OUT="$("$REVOKE" "$@" 2>"$WORLD/err")" || RC=$?
  # shellcheck disable=SC2034  # ERR is read inside the eval strings passed to check
  ERR="$(command cat "$WORLD/err")"
}
collabs() { jq -c . "$WORLD/collaborators.json"; }
gh_calls() { wc -l <"$FAKE_GH_LOG" | tr -d ' '; }

# ---------------------------------------------------------------------------------------------
case_dry_run() {
  rv_setup
  rv --codeowners "$CO" alpha bob
  check "dry run (the default): exit 0" eq "$RC" 0
  check "calls nothing: no gh call at all" eq "$(gh_calls)" 0
  check "prints the exact call" eq "$(tail -n1 <<<"$OUT")" "gh api -X DELETE repos/test/repo/collaborators/bob"
  check "and says it is planned, naming the node" eval '[[ "$(head -n1 <<<"$OUT")" == "# planned: remove collaborator bob (node alpha) from test/repo" ]]'
  rv --dry-run --json --codeowners "$CO" alpha bob
  check "--json: one planned line" \
    eq "$(jq -c '[.mode, .handle, .owner, .repo, .call, .result]' <<<"$OUT")" \
       '["dry-run","alpha","bob","test/repo","gh api -X DELETE repos/test/repo/collaborators/bob","planned"]'
  check "nobody was removed" eq "$(collabs)" '["bob","carol","Dave-X","owner1"]'
  check "the printed call, run by hand, is the removal" eval 'rv --codeowners "$CO" alpha bob; tail -n1 <<<"$OUT" | bash && [ "$(collabs)" = "[\"carol\",\"Dave-X\",\"owner1\"]" ]'
}

case_apply_one_delete() {
  rv_setup
  rv --apply --json --codeowners "$CO" alpha bob
  check "exit 0, done" eq "$RC $(jq -r .result <<<"$OUT")" "0 done"
  check "exactly one gh call, the DELETE" eq "$(jq -sc . "$FAKE_GH_LOG")" '[["api","-X","DELETE","repos/test/repo/collaborators/bob"]]'
  check "bob is gone, nobody else" eq "$(collabs)" '["carol","Dave-X","owner1"]'
  check "carol (named only in a comment) is not a code owner" eval 'rv --apply --codeowners "$CO" r2 carol; [ "$RC" = 0 ]'
  check "bob in a trailing comment is not a code owner (already removed: still one call each)" \
    eval 'rv --apply --codeowners "$CO" r3 bob; [ "$RC" = 0 ] && [ "$(gh_calls)" = 3 ]'
  check "--repo wins over FACTORY_REPO" eval 'rv --codeowners "$CO" --repo other/repo alpha bob; [[ "$OUT" == *"repos/other/repo/collaborators/bob"* ]]'
}

case_refusals() {
  rv_setup
  rv --apply --json --codeowners "$CO" alpha owner1
  check "a CODEOWNERS owner: exit 2, refused, nothing called" eq "$RC $(jq -r .result <<<"$OUT") $(gh_calls)" "2 refused 0"
  check "the refusal names the file" eval '[[ "$ERR" == *"owner1 is a code owner in $CO"* ]]'
  rv --apply --codeowners "$CO" alpha DAVE-x
  check "logins match case-blind (DAVE-x vs @dave-x): refused" eq "$RC $(gh_calls)" "2 0"
  rv --apply --codeowners "$CO" alpha test
  check "the repo's own owner: refused" eq "$RC $(gh_calls)" "2 0"
  rv --apply --codeowners "$CO" alpha 'bob;rm'
  check "an owner that is not a login: refused" eq "$RC $(gh_calls)" "2 0"
  rv --apply --codeowners "$CO" '-x' bob
  check "a flag-looking handle is a usage error" eq "$RC" 1
  rv --apply --codeowners "$CO" 'a b' bob
  check "a handle that is not a handle: refused" eq "$RC $(gh_calls)" "2 0"
  rv --apply alpha musicofhel
  check "the repo's own CODEOWNERS is the default: its owner is refused" \
    eval '[ "$RC" = 2 ] && [[ "$ERR" == *"musicofhel is a code owner in CODEOWNERS"* ]]'
  rv --apply --codeowners "$WORLD/none" alpha bob
  check "no CODEOWNERS file: exit 1, nothing called" eq "$RC $(gh_calls)" "1 0"
  rv --apply alpha
  check "one argument: usage, exit 1" eq "$RC" 1
  check "nobody was removed" eq "$(collabs)" '["bob","carol","Dave-X","owner1"]'
}

case_apply_failure_and_token() {
  rv_setup
  FAKE_GH_FAIL='collaborators/bob' rv --apply --json --codeowners "$CO" alpha bob
  check "a failed DELETE: exit 1, failed with GitHub's message" \
    eq "$RC $(jq -c '[.result, .detail]' <<<"$OUT")" '1 ["failed","gh: Server Error (injected) (HTTP 500)"]'
  # A gh shim in front of the fake records which token the DELETE ran on.
  mkdir -p "$WORLD/shim"
  mkdir -p "$WORLD/tok"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "${GH_TOKEN:-unset}" >>"%s/token.log"\nexec "%s/shim/gh" "$@"\n' "$WORLD" "$WORLD" >"$WORLD/tok/gh"
  chmod +x "$WORLD/tok/gh"
  PATH="$WORLD/tok:$PATH" GH_TOKEN=actions REVOKE_GH_TOKEN=app-token rv --apply --codeowners "$CO" alpha bob
  PATH="$WORLD/tok:$PATH" GH_TOKEN=actions rv --apply --codeowners "$CO" alpha carol
  check "REVOKE_GH_TOKEN, when set, is the token the DELETE runs on; else GH_TOKEN" \
    eq "$(command cat "$WORLD/token.log" | tr '\n' ' ')" "app-token actions "
}

case_shim_collaborators() {
  rv_setup
  check "GET collaborators lists the logins" eq "$(gh api repos/test/repo/collaborators | jq -c 'map(.login)')" '["bob","carol","Dave-X","owner1"]'
  check "DELETE answers no body" eq "$(gh api -X DELETE repos/test/repo/collaborators/dave-x)" ""
  check "and removes case-blind" eq "$(collabs)" '["bob","carol","owner1"]'
  check "another repo is 404" eval '! gh api -X DELETE repos/x/y/collaborators/bob >/dev/null 2>&1'
  check "every other call passes through to the fake" eq "$(gh api repos/test/repo/git/ref/heads/main --jq .ref)" refs/heads/main
}

echo "test_revoke"
for c in dry-run apply-one-delete refusals apply-failure-and-token shim-collaborators; do
  run_case "$c"
done
[ "$FAILED" = 0 ]
