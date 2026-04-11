# Rocq Emacs API for CLI Agents
This repository exposes a small Emacs/Proof-General API for interactive Rocq/Coq checking from CLI agents.

## Entry points

- `coqcheck_until(filename, linenum, columnnum, restart)`
- `coqcheck_until_async(filename, linenum, columnnum, restart)`
- `coqcheck_status(&optional request_id)`
- `coqquery_at_curpoint(query, filename)`
- `save-file(filename)`

## `coqcheck_until`

Arguments:
- `filename`: absolute path to the `.v` file
- `linenum`: 1-based line number, or `nil` to mean end of file
- `columnnum`: 0-based column number, or `nil` to mean end of file
- `restart`: non-`nil` forces restart and builds dependencies of current file using `dune coq top`; `nil` reuses the active scripting session when possible

Return value:
- success: `(:ok t :goal STRING :locked-end INT :target INT)`
- failure: `(:ok nil :error STRING :locked-end INT :target INT)`

Semantics:
- If processing fails at or before the requested point, the function returns `:ok nil` with the Coq error.
- If `linenum` and `columnnum` are both `nil`, the target is the end of the file.
- With `restart=nil`, the function reloads the current buffer from disk incrementally before checking: the "checked-region" only reverts till the first character that was changed.
- With `restart=t`, the file must live under a Dune workspace.
- At end of file there is usually no open proof, so `:goal` may contain the `Show.` error text rather than a useful goal state.

## `coqcheck_until_async`

Arguments:
- same as `coqcheck_until`

Return value:
- success: `(:ok t :async t :id INT :status-file FILE :cancel-file FILE :phase running)`
- failure: `(:ok nil :error STRING)`

Semantics:
- starts one background check on the current Emacs server and returns immediately
- there is at most one active rocqagent operation per Emacs server
- poll with `coqcheck_status`
- cancel from the shell by `touch`ing the returned `:cancel-file`
- use this for long-running checks; it avoids blocking the shell on `emacsclient --eval`

## `coqcheck_status`

Arguments:
- `request_id`: optional request id returned by `coqcheck_until_async`

Return value:
- success: `(:ok t ...status fields...)`
- mismatch / failure: `(:ok nil :error STRING ...)`

Status fields:
- `:busy t|nil`
- `:phase running|done|error|canceled|idle`
- `:subphase dune-deps|checking|query` while running
- `:id INT`
- `:kind check|query`
- `:file STRING`
- `:target INT`
- `:locked-end INT`
- `:cancel-file STRING` while running
- `:result PLIST` after completion
- `:updated-at FLOAT`

Semantics:
- `updated-at` is refreshed during long-running checks
- `locked-end` is refreshed during long-running checks when a proof-script buffer is active; use it to see whether the check is actually advancing through the file
- `:subphase dune-deps` means a `restart=t` request is still in the `dune coq top` dependency-build phase before Proof General starts advancing through the target script buffer
- `:subphase checking` means Proof General / Rocq is advancing through the script
- `:subphase query` means a Rocq query is currently running
- if a `request_id` is provided, `coqcheck_status` verifies that the status belongs to that request
- after completion, the final result is embedded under `:result`

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
- `Show`

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


## Interrupting a long-running request

`emacsclient --eval` calls are serialized by the Emacs server, so a second `emacsclient` request is not a reliable interrupt mechanism.

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
- `:updated-at FLOAT`
- `:kind check|query`
- `:file STRING`
- `:id INT`
- `:cancel-file STRING`

After completion, `:busy nil` and `:phase` becomes one of:
- `done`
- `error`
- `canceled`

For async checks, the final API result is stored under `:result`.

The running request polls for the cancel token and returns:
- `(:ok nil :error "Interrupted" :interrupted t ...)`

## When the Emacs Server Appears Wedged

- IN ALL CAPS: DO NOT JUST ABANDON THE EMACS SERVER OR KILL THE EMACS SERVER.
- A wedged `emacsclient` request may still correspond to a live Rocq / Proof General operation inside Emacs.
- Killing only the Emacs server can leave the underlying Coq / proof-shell process orphaned and still consuming memory/CPU.

Use this recovery sequence instead:

1. Inspect the server status file first.
   - Derive it from the server name as described above, or use `rocqagent_status_path()`.
2. If the status says `:busy t`, extract `:cancel-file` and `touch` it from the shell.
3. Wait for the status file to change to `:phase canceled`, `done`, or `error`.
4. Only after the active request has been canceled/finished should you consider restarting the Emacs server.
5. If you truly must restart the server, first check for surviving Rocq / Proof General / `coqtop` subprocesses associated with that server and clean them up deliberately. Do not assume killing Emacs cleaned them up.

Practical rule:

- If a blocking `coqcheck_until` call seems hung, do not start another random Emacs daemon.
- Do not rely on another `emacsclient --eval` call to interrupt it.
- Read the status file, `touch` the cancel file, and wait for the operation to stop.

## Examples

```sh
emacsclient --eval '(coqcheck_until "/abs/path/file.v" 120 4 nil)'
emacsclient --eval '(coqcheck_until "/abs/path/file.v" nil nil t)'
emacsclient --eval '(coqcheck_until_async "/abs/path/file.v" 120 4 nil)'
emacsclient --eval '(coqcheck_status 7)'
emacsclient --eval '(coqquery_at_curpoint "Check nat." "/abs/path/file.v")'
emacsclient --eval '(save-file "/abs/path/file.v")'
```

## Optimal Usage pattern:
- Before shell-side edits to a `.v` file, call `save-file` with the absolute path.
- IN ALL CAPS: NEVER SKIP THE `save-file` CALL BEFORE SHELL-SIDE EDITS TO A
  `.v` FILE.
- If you shell-edit a file that is open in Emacs, the next API step should be
  `coqcheck_until`, which incrementally reloads the current file. Do not rely
  on a later `save-file` call to repair a stale buffer state.
- For query output (`Search`/`Locate`/`Print`/...), first call `coqcheck_until` to the desired point, then call `coqquery_at_curpoint`.
- For long-running checks, prefer `coqcheck_until_async` + `coqcheck_status` over a blocking `coqcheck_until`.
- Use blocking `coqcheck_until` only when you actually want to wait for the answer immediately.
- Sync vs async: when to use.
- `sync`: cheap local incremental checks, typically `restart=nil`, near the current checked region.
- `async`: any `restart=t`, any large-file check to EOF, or any check you suspect may hang on a tactic.
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
- Once you request `restart=t`, let that restart/recheck finish before editing the current proof file again. Do not edit the file mid-restart. In particular, do not edit `dippedlam.v` while a restart-triggered recheck/build is in flight: the checker / `dune` may read the file while constructing the dependency graph, and mid-build edits can desynchronize what is being checked.
- A long-running `restart=t` request is expected: `dune coq top` may rebuild dependencies before it gets back to the target file. Do not cancel a `restart=t` request merely because it is slow. Use the cancel-file only when the request is clearly wedged or has become obsolete.
- Before every `coqcheck_until` call, do this decision check explicitly:
- if no other `.v` dependency changed since the last successful check, use `restart=nil`;
- if some imported `.v` dependency changed, use `restart=t`.
  Do not improvise additional reasons for `restart=t`.
  Note: even when `restart` is `nil`, `coqcheck_until` still falls back to a full restart path when the file is not open in Emacs or its buffer is open but scripting is inactive (`my-coq--coq-active-buffer-p` is false); `reuse` only happens when it is an active, live coq scripting buffer.
