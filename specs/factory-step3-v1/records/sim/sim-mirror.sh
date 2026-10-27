#!/usr/bin/env bash
set -uo pipefail
S=/tmp/claude-1001/-home-musicofhel/c521cbb6-991b-4e18-801a-9b39f082e7ab/scratchpad/sim/intake
export TMPDIR=$S/tmp; mkdir -p $TMPDIR
export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh" >/dev/null
. $S/repo/tests/fakes/lib.sh
fakegh_setup
trap - EXIT
export FACTORY_ADLC=/home/musicofhel/.npm/_npx/45e3560a1487d0e5/node_modules/.bin/adlc
export FAKE_GH_USER=app/github-actions FAKE_GH_BOT=1 RUNNER_ENVIRONMENT=github-hosted
cd $S/repo
git symbolic-ref --short HEAD
./factory/bin/mirror.sh --apply > $S/mirror-apply.jsonl 2>$S/mirror-apply.err; echo "mirror rc=$?"
grep -v '"unchanged"' $S/mirror-apply.jsonl | jq -c '{action,ticket,issue,gate,reasons,add,result}'
cat $S/mirror-apply.err | tail -3
jq -r '.issues[] | "#\(.number) \(.title)\n labels=\([.labels[].name]|join(","))\n\(.body | split("\n")[0:12] | join("\n"))\n"' $FAKE_GH_ISSUES
cp $FAKE_GH_ISSUES $S/issues-after.json
