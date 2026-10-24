# LAUNCH — factory-step1-v1

Launched 2026-10-24 from the scaffold commit, by hand, as a user unit so it survives the launching session and
account switches:

```
systemd-run --user --unit sf-spec-factory-step1-v1 --collect \
  -p WorkingDirectory=$HOME/software-factory \
  --setenv=PATH="$HOME/.nvm/versions/node/v22.22.0/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" \
  --setenv=HOME=$HOME --setenv=CLAUDE_HANDOFF_SKIP=1 \
  $HOME/spec-loop/run-spec.sh $HOME/software-factory/specs/factory-step1-v1 --max-iterations 48 --model opus
```

Why each flag: `PATH` because a user unit sources no profile (`claude` under nvm, `uv`/`uvx` under
`~/.local/bin`); `CLAUDE_HANDOFF_SKIP=1` so inner sessions do not eat `pending-handoff.md`; `--max-iterations
48` = 8 × 6 rows (the stall guard is the backstop); `--model opus` re-typed on every relaunch; gate = run-spec's
default 220k, never lower.

Abort switch (Aaron): `systemctl --user stop sf-spec-factory-step1-v1`, or write `STATUS: BLOCKED` as the
LEDGER's first line.

Watch: ONE background wait to the end token: `bash ~/spec-loop-chains/wait-lanes.sh spec:factory-step1-v1`
(if wait-lanes resolves lanes by unit name, use `sf-spec-factory-step1-v1`). Log:
`specs/factory-step1-v1/.spec-loop/loop.log`.

Relaunch after a cap-abort or SIGKILL on the same boot: wait for an `iteration N finished` line,
`systemctl --user stop sf-spec-factory-step1-v1; systemctl --user reset-failed sf-spec-factory-step1-v1`, then
the launch command with the remaining iterations.
