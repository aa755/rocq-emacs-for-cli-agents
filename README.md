# rocq-emacs-for-cli-agents

Small Emacs/Proof-General helpers for CLI agents working on Rocq/Coq proofs.
It can connect to an existing emacs+proof-general+company-coq session and drive proofs efficiently.
Here is a [demo](https://asciinema.org/a/vxXdoVQI3qzmscpc)

## Comparison with other approaches

Compared with inserting `Show.` (to see goals) and rebuilding with `dune`, `coqc`, or `rocq c` after every edit:

- full rebuilds after every small change can take minutes on large developments

Compared with Rocq MCP servers such as `rocq-mcp`:

- this uses the Emacs session you are already working on.
- when the agent is working, you can see the proof region, goals, and errors in live in Emacs
- if the agent gets stuck, you can interrupt it and take over directly in the same buffer: you do not need to open the file separately and replay checking again just to inspect what happened

Compared with Emacs MCP servers:
- This is optimized for working on Rocq proofs. The agent can make edits externally (e.g. using sed/..) on the commandline: does not need to do all edits in emacs. Yet, when the agent asks emacs to get the goal/query-result at a point, if the file was already open and scripting/coqtop was already on, the checked-region only reverts till the first point of change.
## API

Public entry points:

- `coqcheck_until(filename, linenum, columnnum, restart)`
- `coqcheck_until_async(filename, linenum, columnnum, restart)`
- `coqcheck_status(&optional request_id)`
- `coqquery_at_curpoint(query, filename)`
- `save-file(filename)`
- `./rocqagent-health [SERVER]`

For long-running checks, use `coqcheck_until_async` and poll `coqcheck_status`.
Status reports include a `:subphase` field, so clients can distinguish
`restart=t` dependency compilation (`dune-deps`) from actual script checking.
Status files now also record `:server-name`, `:emacs-pid`, `:socket-dir`, and `:socket-path`
so shell-side tools can distinguish a live daemon from a stale status file.

When you need to know whether a server is actually reachable, do not trust the
status file by itself. Run `./rocqagent-health SERVER` instead. It combines:

- the persisted status file
- the recorded Emacs PID
- the expected socket path
- a short `emacsclient` ping

This is the intended way to tell apart:

- live and responsive
- stale/dead PID
- stale/dead socket
- RPC path wedged even though the status file says `:busy nil`

See [AGENTS.md](AGENTS.md) for the full API contract.

## Setup

Load `rocqagent.el` after Proof General:

```elisp
(load "/path/to/rocqagent.el")
```

Rocq Project Requirements:

- This API uses dune to build dependencies of the current file when the agent requests a fresh build. so a dune build system is needed.
- A _CoqProject is also needed by proof-general/company-coq to pass the right flags (e.g. -Q) to Coq. There are tools to build _CoqProject automatically from dune: e.g. see SkyLabsAI repos.
- AGENTS.md in the project or some active skills file should ask the agent to read AGENTS.md in this repo
