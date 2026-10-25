# TB1 — The rendered per-run policy (ticket T17; ruling Q1)

Session 3 of the loop, 2026-10-25 (~22:50Z). No prep exists for this spec (`prep/` is absent).
Commit `Ticket: T17` (hash in LEDGER). Tools: vetto 0.6.5, tamperguard v0.2.0 (a user-level uv tool),
uv 0.10.0, kernel 6.18 WSL2.

## 1. What was built

| file | what |
|---|---|
| `factory/bin/lib/policy-render.sh` (new) | `policy_roots <wt> <factory-home> [tool]`, `policy_render <template> <out> <root>...`, `policy_tamperguard <wt> <policy> <range>` |
| `factory/bin/run.sh` | `on_success` derives the roots, renders `$FACTORY_HOME/run/policy/<run id>.build.toml`, and runs the step under it. A failed render → action `policy-render-failed`, reason `tamperguard-error`, and vetto never starts. tamperguard's stderr is copied to `$LOGBASE.tamperguard.err` |
| `docs/adr/0005-run-loop-cli-reality.md` | amendment "T17, decision 8 under the rendered policy" (I14, the roots, the fail-closed paths, the real HOME) |
| `tests/test_run.sh` | `fake_uv` (tamperguard laid out as uv installs it); cases `policy-render`, `policy-missing-root`, `policy-render-lib`; `tamper` checks the stderr is kept; `argv` checks vetto's `--policy` is the render |
| `tests/live/test_render_live.sh` (new) | the step under the real vetto: render, scratch HOME, template, drop-one-root, real HOME |

`factory/policy/**` is untouched (I15). The diff stays inside T17's scope globs, plus this records
file and the LEDGER.

### 1.1 The roots (measured, not guessed)

`policy_roots` returns, in order:

1. the worktree's common git dir (`git rev-parse --path-format=absolute --git-common-dir`, then
   `pwd -P`);
2. `$FACTORY_HOME/bin` and `$FACTORY_HOME/uv`, when they exist (resolved);
3. the install root of `tamperguard` as PATH resolves it: `readlink -f`, and `<root>/bin/<exe>` →
   `<root>`;
4. the install root of the interpreter named by the resolved tool's `#!` line (an absolute path, or
   `/usr/bin/env <name>` through PATH): `readlink -f`, same rule.

A root inside another root is dropped. On a joined node, `$FACTORY_HOME/uv` holds both the tool and its
python, because join.sh installs it with `UV_TOOL_DIR=$FH/uv/tools UV_PYTHON_INSTALL_DIR=$FH/uv/python`.

**Decision:** items 1, 3 and 4 are required, and when one is missing the claim fails closed. Item 2 is
"when they exist". The SPEC names `$FH/bin` and `$FH/uv`, but this box has no `~/.factory` (TB0 §1.4),
and I14 requires that every entry is an existing directory. The roots come from the resolved tool, not
from either layout (HANDOFF gotcha 5 of session 2).

**Correction to session 2's HANDOFF gotcha 4.** That note said a root at only `readlink -f`'s dir would
miss the middle link (`cpython-3.14` → `cpython-3.14.3`). This was measured and it is wrong: the
resolved install root alone works. Landlock checks the file that is opened, not the links walked to
reach it. Probe `~/.cache/tb1-run/probe.sh` (node-local):

```
PYR=/home/musicofhel/.local/share/uv/python/cpython-3.14.3-linux-x86_64-gnu
[all] vetto=125 rc=0 json={"verdict":"ok","score":0,"findings":[]} err=
[installroot] vetto=125 rc=0 json={"verdict":"ok","score":0,"findings":[]} err=
[installroot-plus-linkparent] vetto=125 rc=0 json={"verdict":"ok","score":0,"findings":[]} err=
[no-tool] vetto=125 rc=126 json= err=tamperguard: line 1: /home/musicofhel/.local/bin/tamperguard: Permission denied
```

So the render on this box adds exactly three roots, and §3 shows each one is load-bearing.

### 1.2 I14 in the code

`policy_render` refuses the render and writes nothing when:

- a root is not absolute, or is not an existing directory;
- a root is `$HOME` or a directory above it (checked after `pwd -P`);
- the template's `[filesystem]` lacks exactly one single-line string-array `allow_read`.

It adds roots in order without duplicates. The new array is printed as JSON, and a JSON string array
is a TOML basic-string array (same escapes). Every other line of the template is copied byte for byte.
It never writes `allow_write` or `[network]`.

## 2. Offline proof (`make test`)

```
$ make test          → 15 files PASS (test rc=0)
$ make lint          → rc 0 (shellcheck -S warning over every factory/tests shell file; actionlint)
$ CASES="policy-render policy-missing-root policy-render-lib tamper argv" bash tests/test_run.sh → 62 ok, 0 FAIL
```

| AC | case | what it asserts |
|---|---|---|
| 1 | `policy-render` | The test has its own awk TOML flattener (`[table] key = value`, independent of the lib). Every flattened line except `[filesystem] allow_read` equals the template's. `[network] mode = "off"` and `allow_write` are unchanged. allow_read = the template's entries + exactly `[<clone>/.git, <uv>/tools/tamperguard, <uv>/python/cpython-9.9.9-fake]`, each absolute, existing, and not `$HOME` or above it. The render is kept and is what vetto's `--policy` named. The second half is the joined-node layout (`$FH/bin` + tool under `$FH/uv`), which gives `[.git, $FH/bin, $FH/uv]` |
| 2 | `policy-missing-root` | The interpreter's version dir is removed, so its link dangles. Result: exit 1, `released tamperguard-error`, actions include `policy-render-failed` and no `tamperguard`. There is no vetto session, no tamperguard call and no render. The reason is in `<run id>.tamperguard.err`. Scope-check did not run, nothing was pushed, and the lock was released |
| 3 | `tamper` (error leg) | `Traceback (most recent call last): injected` is in `$FACTORY_HOME/run/logs/<run id>.tamperguard.err` |
| — | `policy-render-lib` | Refuses `$HOME`, `/`, `$HOME/..`, a relative root, a missing root, a multi-line allow_read, and an allow_read outside `[filesystem]`; dedupes a repeated root; resolves `#!/usr/bin/env <name>` through PATH; fails on no `#!`, no git dir, and no tool |
| — | `argv` | vetto's argv is `--profile strict --policy $FACTORY_HOME/run/policy/<run id>.build.toml --tui none --` |

Mutation check (each mutation restored afterwards):

| mutation | result |
|---|---|
| render flips `"off"` → `"allowlist"` | `policy-render` FAIL (2 checks × 2 layouts) |
| interpreter failure ignored (root `/usr`) | `policy-missing-root` FAIL (3 checks) |
| the stderr copy line deleted | `tamper` FAIL |
| the `$HOME` guard defeated | `policy-render-lib` FAIL (`$HOME`, `$HOME/..`) |

## 3. Live proof (`tests/live/test_render_live.sh`)

The scratch tree is `~/.cache/factory-render-live.*`: a clone with two commits (a test file grows) and
a detached linked worktree at the tip, as the loop builds. The roots are derived under the **real**
HOME, so I14's `$HOME` check is against the real one. vetto runs `policy_tamperguard`, which is
exactly run.sh's step.

```
test_render_live
    ok   vetto is the pinned 0.6.5
    INFO tamperguard /home/musicofhel/.local/bin/tamperguard -> /home/musicofhel/.local/share/uv/tools/tamperguard/bin/tamperguard; interpreter /home/musicofhel/.local/share/uv/tools/tamperguard/bin/python -> /home/musicofhel/.local/share/uv/python/cpython-3.14.3-linux-x86_64-gnu/bin/python3.14
    INFO root /home/musicofhel/.cache/factory-render-live.4P9FDl/clone/.git
    INFO root /home/musicofhel/.local/share/uv/tools/tamperguard
    INFO root /home/musicofhel/.local/share/uv/python/cpython-3.14.3-linux-x86_64-gnu
    ok   the roots: the clone's common git dir first
    ok     then at least the tool's and the interpreter's install roots
    ok   I14: the render differs from build.toml only on the allow_read line
    ok     allow_read = the template's entries + the roots
    ok     (×3) <root>: an absolute existing directory, not $HOME or above it
    INFO render, scratch HOME: rc=0 verdict=ok
    ok   under the render and a scratch HOME: tamperguard rc 0 and a JSON verdict
    ok     an ok verdict on this benign diff
    INFO template, scratch HOME: rc=126 verdict=none (tamperguard: line 1: /home/musicofhel/.local/bin/tamperguard: Permission denied )
    ok   under build.toml itself the step does not pass (rc 126 or no verdict: tamperguard-error)
    INFO minus <clone>/.git: rc=0 verdict=none (tamperguard: empty diff, nothing to scan )
    INFO minus /home/musicofhel/.local/share/uv/tools/tamperguard: rc=126 verdict=none (… Permission denied )
    INFO minus /home/musicofhel/.local/share/uv/python/cpython-3.14.3-linux-x86_64-gnu: rc=126 verdict=none (… bin/python: bad interpreter)
    INFO render, real HOME: rc=none verdict=none; vetto: vetto: error: Sandbox process spawn failure: … :mask overlay /home/musicofhel/.aws: mount operation failed: bind /dev/null over /home/musicofhel/.aws: Not a directory (os error 20
    ok   real HOME with the ~/.aws symlink defect: vetto refuses to start, the step never runs (fail-closed)
```

(The `(×3)` and `…` lines are condensed here. The full log is `~/.cache/tb1-run/render-live.log`. A
second run after the lint fix printed the same results, in scratch dir `…Ck42Ew`.)

- **Python dir used:** `/home/musicofhel/.local/share/uv/python/cpython-3.14.3-linux-x86_64-gnu`, the
  `readlink -f` install root of the tool's `bin/python`.
- **Real HOME (ruling Q2):** vetto 0.6.5 refuses to start because of the `~/.aws` symlink (ADR-0005
  amendment T6 item 10). It writes no rc file, so run.sh reads it as `tamperguard-error`, which fails
  closed. The render cannot fix this. It is a vetto masking defect, and the box's own condition.

`make live`: `test_bwrap_shim_live`, `test_join_live`, `test_policy_live` and `test_render_live` all
PASS. **`test_smoke_live.sh` was not run in this row.** It drives a real fleet run with the owner's
Claude login, so it is TB3's DoD part A (ticket T19). Its vetto audit check (L257) still expects
`--policy …/factory/policy/build.toml` and will need the render path. That file is in T19's scope, not
T17's (HANDOFF).

## 4. Desk note (I15, not committed)

Two lines in `factory/policy/` still describe running the template directly:

- `factory/policy/build.toml` L6–9 ("Invoke it exactly so … `--policy factory/policy/build.toml`");
- `factory/policy/README.md` L12.

The run loop now runs a per-claim render that only adds read roots (ADR-0005 amendment T17), and the
comments should say so. Per I15, this is a desk edit, so it is recorded in HANDOFF.

## 5. Result

T17's acceptance criteria:

- **1–3:** met by `make test` (§2).
- **4:** met by `tests/live/test_render_live.sh` (§3).
- **5:** `grep -n "rendered policy" docs/adr/0005-run-loop-cli-reality.md` → lines 239 and 247.
- **6:** `make lint` 0.
