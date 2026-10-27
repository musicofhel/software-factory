# LAUNCH — factory-step3-v1

Launched 2026-10-26 after the read-only pipeline simulation (records/sim/), by hand, as a user unit so it survives the launching session and
account switches:

```
systemd-run --user --unit sf-spec-factory-step3-v1 --collect \
  -p WorkingDirectory=$HOME/software-factory \
  --setenv=PATH="$HOME/.nvm/versions/node/v22.22.0/bin:$HOME/.cargo/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" \
  --setenv=HOME=$HOME --setenv=CLAUDE_HANDOFF_SKIP=1 \
  $HOME/spec-loop/run-spec.sh $HOME/software-factory/specs/factory-step3-v1 --max-iterations 104 --model opus
```

Why each flag: `PATH` because a user unit sources no profile (`claude` under nvm, `uv`/`uvx` under
`~/.local/bin`); `CLAUDE_HANDOFF_SKIP=1` so inner sessions do not eat `pending-handoff.md`; `--max-iterations
104` = 8 × 13 rows (the stall guard is the backstop); `--model opus` re-typed on every relaunch; gate = run-spec's
default 220k, never lower.

Abort switch (Aaron): `systemctl --user stop sf-spec-factory-step3-v1`, or write `STATUS: BLOCKED` as the
LEDGER's first line.

Watch: ONE background wait to the end token. `~/spec-loop-chains/wait-lanes.sh` only knows `rb-spec-*` units,
and this unit is deliberately NOT `rb-spec-*` (the reserve-ledger api-sec chain starts only when no `rb-spec-*`
unit is active; an `rb-spec-` name here would block it). So the wait is:

```
while systemctl --user is-active --quiet sf-spec-factory-step3-v1 \
  && ! grep -qE '^STATUS: (DONE|BLOCKED)' specs/factory-step3-v1/LEDGER.md 2>/dev/null; do sleep 300; done
```

Log: `specs/factory-step3-v1/.spec-loop/loop.log`.

Relaunch after a cap-abort or SIGKILL on the same boot: wait for an `iteration N finished` line,
`systemctl --user stop sf-spec-factory-step3-v1; systemctl --user reset-failed sf-spec-factory-step3-v1`, then
the launch command with the remaining iterations.
