# Rocq Emacs API for CLI Agents

This repository exposes a small Emacs/Proof-General API for interactive Rocq/Coq checking from CLI agents.

## Entry points

- `coqcheck_until(filename, linenum, columnnum, restart)`
- `coqquery_at_curpoint(query, filename)`
- `rocqagent_status_path()`

## Requirements

- Emacs with Proof General loaded
- Rocq/Coq mode active for `.v` files
- A Dune workspace for `restart=t`

## `coqcheck_until`

Arguments:
- `filename`: absolute path to the `.v` file
- `linenum`: 1-based line number, or `nil` to mean end of file
- `columnnum`: 0-based column number, or `nil` to mean end of file
- `restart`: non-`nil` forces restart via `dune coq top`; `nil` reuses the active scripting session when possible

Return value:
- success: `(:ok t :goal STRING :locked-end INT :target INT)`
- failure: `(:ok nil :error STRING :locked-end INT :target INT)`

Semantics:
- If processing fails at or before the requested point, the function returns `:ok nil` with the Coq error.
- If `linenum` and `columnnum` are both `nil`, the target is the end of the file.
- With `restart=nil`, the function reloads the current buffer from disk incrementally before checking.
- With `restart=t`, the file must live under a Dune workspace.

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
- If the query changes the checked boundary unexpectedly, the API rewinds and returns an error.

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

## Interrupting a long-running request

`emacsclient --eval` calls are serialized by the Emacs server, so a second `emacsclient` request is not a reliable interrupt mechanism.

Use the shell-visible status file instead:
- call `emacsclient --eval '(rocqagent_status_path)'`
- read the plist in that file while the request is running
- extract `:cancel-file`
- `touch` that path from the shell

While busy, the status file contains a plist of the form:
- `:busy t`
- `:server STRING`
- `:updated-at FLOAT`
- `:kind check|query`
- `:file STRING`
- `:id INT`
- `:cancel-file STRING`

The running request polls for the cancel token and returns:
- `(:ok nil :error "Interrupted" :interrupted t ...)`

## Examples

```sh
emacsclient --eval '(coqcheck_until "/abs/path/file.v" 120 4 nil)'
emacsclient --eval '(coqcheck_until "/abs/path/file.v" nil nil t)'
emacsclient --eval '(coqquery_at_curpoint "Check nat." "/abs/path/file.v")'
```
