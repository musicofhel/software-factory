#!/usr/bin/env bash
set -uo pipefail
S=/tmp/claude-1001/-home-musicofhel/c521cbb6-991b-4e18-801a-9b39f082e7ab/scratchpad/sim/intake
export TMPDIR=$S/tmp; mkdir -p $TMPDIR
. $S/repo/tests/fakes/lib.sh
fakegh_setup; trap - EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
git init -q -b main "$WORLD/repo"; mkdir -p "$WORLD/repo/.adlc"; : >"$WORLD/repo/.adlc/manifest.jsonl"
A=/home/musicofhel/.npm/_npx/45e3560a1487d0e5/node_modules/.bin/adlc
export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh" >/dev/null
( cd $S/repo; for t in T20 T21; do $A ticket show $t --json | jq -c '.ticket'; done ) | jq -s . > $WORLD/store.json
export FACTORY_ADLC="$FAKES_DIR/adlc" FAKE_ADLC_STORE="$WORLD/store.json"
export FAKE_GH_USER=app/github-actions FAKE_GH_BOT=1 RUNNER_ENVIRONMENT=github-hosted
H20=$(FAKE_ADLC_STORE=$WORLD/store.json $FAKES_DIR/adlc ticket show T20 --json | jq -r .ticketHash)
H21=$(FAKE_ADLC_STORE=$WORLD/store.json $FAKES_DIR/adlc ticket show T21 --json | jq -r .ticketHash)
rec(){ printf '%s\n' "$1" >> "$WORLD/repo/.adlc/manifest.jsonl"; }
for t in T20:$H20 T21:$H21; do id=${t%%:*}; h=${t#*:}
 rec "{\"gate\":\"spec-lint\",\"ticket\":\"$id\",\"data\":{\"verified\":true}}"
 rec "{\"gate\":\"coldstart\",\"ticket\":\"$id\",\"data\":{\"cache\":{\"ticketHash\":\"$h\",\"gaps\":[]}}}"
 rec "{\"gate\":\"merge-forecast\",\"ticket\":\"$id\",\"data\":{\"certifiedWidth\":1}}"
done
cd $WORLD/repo
echo "== round 1: T21 open, T20 depends on it (real forecast)"
$S/repo/factory/bin/mirror.sh --apply --forecast $S/forecast.json | jq -c '{action,ticket,issue,gate,reasons,add}'
echo "== claim view (dry run, light node)"
$S/repo/factory/bin/claim.sh --json --capacity light | jq -c '{locked,candidates:[.candidates[]|{number,weight}]}'
echo "== round 2: T21 completed by post-merge; forecast now [[T20]]"
jq 'map(if .id=="T21" then .completed=true else . end)' $WORLD/store.json > $WORLD/s2 && mv $WORLD/s2 $WORLD/store.json
echo '{"pairs":[],"waves":[["T20"]],"mergeOrder":["T20"],"firstWaveWidth":1,"certifiedWidth":1,"warnings":[],"gateFailures":[]}' > $WORLD/f2.json
$S/repo/factory/bin/mirror.sh --apply --forecast $WORLD/f2.json | jq -c '{action,ticket,issue,gate,reasons,add,remove}'
jq -r '.issues[] | "#\(.number) \(.state) \([.labels[].name]|join(","))"' $FAKE_GH_ISSUES
