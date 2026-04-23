---
name: rocqemacs
description: Use when a task involves Rocq/Coq proof work through an existing Emacs + Proof General session. Provides the `rocqagent-call`, `rocqagent-health`, and `rocqagent-cleanup` shell entrypoints plus the `coqcheck_until`, `coqquery_at_curpoint`, and `save-file` RPC workflow for efficient incremental checking, queries, cancellation, and server health management.
---

# Rocq Emacs API for CLI Agents
This repository exposes a small Emacs/Proof-General API for interactive Rocq/Coq checking from CLI agents.

## Entry points

- `scripts/rocqagent-call SERVER ELISP`
- `scripts/rocqagent-health [SERVER]`
- `scripts/rocqagent-cleanup SERVER`

## `rocqagent-call`

Use `scripts/rocqagent-call SERVER ELISP` as the only shell entry point for Emacs RPCs.

The supported `ELISP` expressions are:
- `'(coqcheck_until FILENAME LINENUM COLUMNNUM RESTART)'`
- `'(coqquery_at_curpoint QUERY FILENAME)'`
- `'(save-file FILENAME)'`

`rocqagent-call`:
- serializes shell-side RPCs per Emacs server
- refuses a second request while a check is already running
- refuses if another raw `emacsclient` process is already talking to the same server
- refuses stale dead-server cases that would otherwise look live

## `coqcheck_until`

Arguments:
- `filename`: absolute path to the `.v` file
- `linenum`: 1-based line number, or `nil` to mean end of file
- `columnnum`: 0-based column number, or `nil` to mean end of file
- `restart`: non-`nil` forces restart and builds dependencies of current file using `dune coq top`; `nil` reuses the active scripting session when possible

Return value:
- success: `(:ok t :locked-end INT :target INT [:goal STRING])`
- failure: `(:ok nil :error STRING :locked-end INT :target INT [:goal STRING])`

Semantics:
- If processing fails at or before the requested point, the function returns `:ok nil` with the Coq error.
- If `linenum` and `columnnum` are both `nil`, the target is the end of the file.
- With `restart=nil`, the function reloads the current buffer from disk incrementally before checking: the "checked-region" only reverts till the first character that was changed.
- With `restart=t`, the file must live under a Dune workspace. Frivolous `restart=t` requests may not be honored when no dependency actually changed and the existing live session can be reused safely.
- `:goal` is included only when a proof is currently active and a fresh goal is available.
- On proof errors, `:goal` reports the post-error current goal when Proof General still has an active proof.
- Outside an active proof, `:goal` is omitted rather than returning stale goals or `Show.` errors.

## `coqquery_at_curpoint`

Arguments:
- `query`: Rocq query string, with or without the trailing `.`
- `filename`: absolute path to the `.v` file whose checked state should be queried

Return value:
- success: `(:ok t :query STRING :locked-end INT)`
- failure: `(:ok nil :error STRING :locked-end INT)`

Semantics:
- The caller must first establish the checked state with `coqcheck_until`.
- The query is sent directly to Coq through Proof General; it is not inserted into the file.

Allowed query prefixes:
- `Search`
- `SearchAbout`
- `SearchPattern`
- `About`
- `Print`
- `Locate`
- `Check`
- `Compute`
- `Eval`

## `save-file`

Arguments:
- `filename`: absolute path to the `.v` file

Return value:
- success with no live buffer: `(:ok t :file FILE :buffer-live nil :saved nil)`
- success with live buffer: `(:ok t :file FILE :buffer-live t :saved BOOL :modified BOOL)`
- failure: `(:ok nil :error STRING)`

Semantics:
- If Emacs already has a live buffer visiting `filename`, save that buffer.
- If no live buffer exists, do nothing and return success.
- This is intended as a pre-edit sync helper before shell-side edits.
- IN ALL CAPS BECAUSE THIS IS EASY TO GET WRONG: ALWAYS CALL `save-file` BEFORE
  ANY SHELL-SIDE EDIT TO A `.v` FILE THAT MAY BE OPEN IN EMACS.
- The main purpose of `save-file` is to avoid clobbering newer buffer contents
  with shell-side edits. This is a required precondition for mixed
  Emacs+shell workflows.

## `rocqagent-health`

Use `scripts/rocqagent-health [SERVER]` for shell-side diagnosis. It combines:
- the static status file
- the recorded Emacs PID
- the expected socket path
- an optional `emacsclient` ping

It is the supported way to distinguish:
- live and responsive
- live but busy
- stale dead PID/socket
- RPC-unresponsive server

## `rocqagent-cleanup`

Use `scripts/rocqagent-cleanup SERVER` to tear down one rocqagent server safely on Linux.

It does this in order:
- touch the current `:cancel-file` if the server is busy
- if the server is still responsive, call the graceful Proof General shutdown path
- if anything remains, kill only the validated process roots for that server and their descendants

The targeted roots are:
- the exact Emacs server PID for that server
- the tracked proof shell PID for that server
- the tracked active worker PID for that server

The implementation validates Linux start-time ticks from the status file before using recorded PIDs, so stale status files do not cause it to kill a reused unrelated PID.


## Interrupting a long-running request

`emacsclient --eval` calls are serialized by the Emacs server, so a second
`emacsclient` request is not a reliable interrupt mechanism.

Use the shell-visible status file instead:
- derive the status path directly from the Emacs server name:
  `status_dir="${TMPDIR:-/tmp}/rocqagent"`
  `server="${EMACS_SOCKET_NAME:-default}"`
  `server_tag=$(printf '%s' "$server" | sed 's/[^[:alnum:]_.-]/_/g')`
  `status_file="$status_dir/$server_tag.status"`
- read the plist in that file while the request is running
- extract `:cancel-file`
- `touch` that path from the shell

The status path is static for a given Emacs server. The random per-operation path is `:cancel-file`, not the status file.

While busy, the status file contains a plist of the form:
- `:busy t`
- `:phase running`
- `:subphase dune-deps|checking|query`
- `:server STRING`
- `:server-name STRING`
- `:emacs-pid INT`
- `:socket-dir STRING`
- `:socket-path STRING`
- `:updated-at FLOAT`
- `:kind check|query`
- `:file STRING`
- `:id INT`
- `:cancel-file STRING`

After completion, `:busy nil` and `:phase` becomes one of:
- `done`
- `error`
- `canceled`

For backgrounded `coqcheck_until` calls, the final API result is stored under `:result`.

The running request polls for the cancel token and returns:
- `(:ok nil :error "Interrupted" :interrupted t ...)`

## When the Emacs Server Appears Wedged

- IN ALL CAPS: DO NOT JUST ABANDON THE EMACS SERVER OR KILL THE EMACS SERVER.
- A wedged `emacsclient` request may still correspond to a live Rocq / Proof General operation inside Emacs.
- Killing only the Emacs server can leave the underlying Coq / proof-shell process orphaned and still consuming memory/CPU. 

Use this recovery sequence instead:

1. Inspect the server status file first.
   - Derive it from the server name as described above.
2. Run `scripts/rocqagent-health SERVER`.
   - This combines the status file, recorded Emacs PID, recorded socket path, and a short `emacsclient` ping.
   - Use it to distinguish `busy_live`, `idle_live`, `stale_dead_pid_*`, `stale_dead_socket_*`, and `*_rpc_unresponsive`.
3. If the health check says the server is live and the status says `:busy t`, extract `:cancel-file` and `touch` it from the shell.
4. Wait for the status file to change to `:phase canceled`, `done`, or `error`.
5. Only after the active request has been canceled/finished should you consider restarting the Emacs server.
6. If you truly must restart the server, first check for surviving Rocq / Proof General / `coqtop` subprocesses associated with that server and clean them up deliberately. Do not assume killing Emacs cleaned them up.
   THERE MAY BE OTHER ROCQ/ROCQWORKER/EMACS PROCESSES OF OTHER USERS. NEVER EVER DO KILLALL EMACS OR KILLALL ROCQWORKER...
Practical rule:

- If a blocking `coqcheck_until` call seems hung, do not start another random Emacs daemon.
- Do not rely on another `emacsclient --eval` call to interrupt it.
- Run `scripts/rocqagent-health SERVER` first so you know whether the server is live, dead, or RPC-wedged.
- Then read the status file, `touch` the cancel file when appropriate, and wait for the operation to stop.

## One RPC At A Time

- IN ALL CAPS: SEND AT MOST ONE `emacsclient` REQUEST AT A TIME TO A GIVEN ROCQAGENT SERVER.
- If `coqcheck_until` is still running, do not send `coqquery_at_curpoint`, another `coqcheck_until`, or even a trivial `emacsclient --eval '(+ 1 2)'` to the same server.
- Wait for the active request to finish, or cancel it via the current `:cancel-file`, before sending the next request.
- For shell-side automation, prefer `scripts/rocqagent-call SERVER ELISP` instead of raw `emacsclient --eval ...`.
- `scripts/rocqagent-call` refuses to queue a second shell-side request while the server status says `:busy t`.
- `scripts/rocqagent-call` also refuses to start when another `emacsclient` process is already talking to the same server.
- `scripts/rocqagent-call` also refuses to mistake a stale `:busy t` status from a dead server for a live busy request.
- The intended async pattern is: background the synchronous `coqcheck_until` in the shell, then inspect/cancel via the static status file rather than by sending another RPC.
- When a server really needs to be torn down, use `scripts/rocqagent-cleanup SERVER` rather than ad hoc `kill` / `killall`.

## Examples

```sh
scripts/rocqagent-call codex-checkmin25 '(coqcheck_until "/abs/path/file.v" 120 4 nil)'
scripts/rocqagent-call codex-checkmin25 '(coqcheck_until "/abs/path/file.v" nil nil t)'
scripts/rocqagent-call codex-checkmin25 '(coqquery_at_curpoint "Check nat." "/abs/path/file.v")'
scripts/rocqagent-call codex-checkmin25 '(save-file "/abs/path/file.v")'
scripts/rocqagent-health --skip-ping codex-checkmin25
scripts/rocqagent-health codex-checkmin-inline
scripts/rocqagent-cleanup codex-checkmin25
```

Background long-running check from the shell:

```sh
scripts/rocqagent-call codex-checkmin25 '(coqcheck_until "/abs/path/file.v" nil nil t)' >/tmp/check.out 2>/tmp/check.err &
status_dir="${TMPDIR:-/tmp}/rocqagent"
server_tag=$(printf '%s' 'codex-checkmin25' | sed 's/[^[:alnum:]_.-]/_/g')
status_file="$status_dir/$server_tag.status"
cat "$status_file"
```

## Optimal Usage pattern:
- Before shell-side edits to a `.v` file, call `save-file` with the absolute path.
- IN ALL CAPS: NEVER SKIP THE `save-file` CALL BEFORE SHELL-SIDE EDITS TO A
  `.v` FILE.
- If you shell-edit a file that is open in Emacs, the next API step should be
  `coqcheck_until`, which incrementally reloads the current file. Do not rely
  on a later `save-file` call to repair a stale buffer state.
- For query output (`Search`/`Locate`/`Print`/...), first call `coqcheck_until` to the desired point, then call `coqquery_at_curpoint`.
- For long-running checks, background `coqcheck_until` in the shell and poll the status file directly or via `scripts/rocqagent-health --skip-ping SERVER`.
- Use foreground `coqcheck_until` only when you actually want to wait for the answer immediately.
- Foreground vs background: when to use.
- `foreground`: cheap local incremental checks, typically `restart=nil`, near the current checked region.
- `background`: any `restart=t`, any large-file check to EOF, or any check you suspect may hang on a tactic.
- IN ALL CAPS: DO NOT USE `coqquery_at_curpoint "Show." ...` FOR GOAL INSPECTION. `coqcheck_until` ALREADY RETURNS THE GOAL/ERROR STATE AT THE CHECKED POINT. Use `coqquery_at_curpoint` only for non-goal queries such as `Search`, `Locate`, `Print`, `Check`, `Compute`, or `Eval`.
- Dont edit files via emacs/emacsclient, just use this to see goal at point, or to see errors
- For large Coq files (e.g. >1000 lines), do not use `dune build` during iterative editing/debugging; use the Emacs Coq API (`coqcheck_until` / `coqquery_at_curpoint`) instead. Use `dune` for these files only as an explicit final verification step when requested.
- When all edits are done and `coqcheck_until(file, nil, nil, nil)` says no error, do use `dune` for a final check before telling the user that the task is done.
- In a very large proof, make edits as close as possible to the end of the currently checked region to minimize rechecking.
  Example: introduce temporary local lemmas near that point (e.g., with `Set Nested Proofs Allowed`) instead of adding global lemmas far above.
- In a very large proof, when you want to keep the ability to rewind to earlier points cheaply, do not check through the proof terminator (`Qed.`/`Abort.`/`Admitted.`).
  Check only up to just before the terminator.
- Line numbers can become stale after edits. Before boundary checks near `Qed.`/`Abort.`/`Admitted.`, re-read the file with line numbers and recompute the exact target line.
- When working on a large proof, make helper edits as locally as possible near the current proof point instead of near the top of the file. Prefer local nested lemmas or local `assert` blocks over top-level helper insertions that force long rechecks.
- If a large proof needs local nested helper lemmas, use `Set Nested Proofs Allowed.` before introducing them.
- If you edit another `.v` file that may be a dependency of the current proof file, use `restart=t` in `coqcheck_until` to force a clean recheck path with updated dependencies. Do not use `restart=t` otherwise as that will show you down as the whole file will be checked again.
- Use `restart=t` iff some other `.v` dependency of the current file changed since the last successful check.
  Current-file edits do not justify `restart=t`: `coqcheck_until(..., restart=nil)` already does an incremental reload of the current buffer/file before checking.
  In particular, shell-editing the current file is still a `restart=nil` case.
- If no dependency actually changed, a frivolous `restart=t` request may be treated as a normal incremental reuse of the existing live session rather than a destructive restart.
- IN ALL CAPS: `restart=t` IS A ONE-SHOT RECOVERY FOR DEPENDENCY CHANGES, NOT A
  MODE YOU STAY IN.
- AFTER YOU HAVE SUCCESSFULLY DONE THE DEPENDENCY-REFRESHING CHECK WITH
  `restart=t`, ALL SUBSEQUENT CHECKS MUST GO BACK TO `restart=nil` UNLESS SOME
  OTHER IMPORTED `.v` FILE CHANGED AGAIN.
- DO NOT KEEP USING `restart=t` JUST BECAUSE A DEPENDENCY CHANGED EARLIER IN
  THE SESSION. ONCE THAT CHANGE HAS BEEN INCORPORATED BY A SUCCESSFUL RESTARTED
  CHECK, FURTHER CURRENT-FILE-ONLY ITERATION IS AGAIN A `restart=nil` CASE.
- Once you request `restart=t`, let that restart/recheck finish before editing the current proof file again. Do not edit the file mid-restart. In particular, do not edit `dippedlam.v` while a restart-triggered recheck/build is in flight: the checker / `dune` may read the file while constructing the dependency graph, and mid-build edits can desynchronize what is being checked.
- A long-running `restart=t` request is expected: `dune coq top` may rebuild dependencies before it gets back to the target file. Do not cancel a `restart=t` request merely because it is slow. Use the cancel-file only when the request is clearly wedged or has become obsolete.
- Before every `coqcheck_until` call, do this decision check explicitly:
- if no other `.v` dependency changed since the last successful check, use `restart=nil`;
- if some imported `.v` dependency changed, use `restart=t`.
  Do not improvise additional reasons for `restart=t`.
  Note: even when `restart` is `nil`, `coqcheck_until` still falls back to a full restart path when the file is not open in Emacs or its buffer is open but scripting is inactive (`my-coq--coq-active-buffer-p` is false); `reuse` only happens when it is an active, live coq scripting buffer.
