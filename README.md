# rocq-emacs-for-cli-agents

Small Emacs/Proof-General helpers for CLI agents working on Rocq/Coq proofs.
It can connect to an existing emacs+proof-general+company-coq session and drive proofs efficiently.
Here is a [demo](https://asciinema.org/a/vxXdoVQI3qzmscpc)

This repo also ships a Codex skill at [skills/rocqemacs/SKILL.md](skills/rocqemacs/SKILL.md).

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

- `./rocqagent-call SERVER ELISP`
- `./rocqagent-health [SERVER]`
- `./rocqagent-cleanup SERVER`

The supported `ELISP` payloads for `rocqagent-call` are:

- `'(coqcheck_until FILENAME LINENUM COLUMNNUM RESTART)'`
- `'(coqquery_at_curpoint QUERY FILENAME)'`
- `'(save-file FILENAME)'`

`coqcheck_until` returns `:goal` only when a proof is currently active.
On proof errors it includes both `:error` and the fresh current `:goal` when
available. Outside an active proof it omits `:goal` rather than returning stale
goal text or a `Show.` error.
Before any proof-state mutation, `coqcheck_until` also runs functions from
`rocqagent-before-refresh-check-functions` on the on-disk file contents in a
temporary `coq-mode` buffer. A validator returns `nil` to allow checking or a
string to reject the request; validation failures come back as
`(:ok nil :error ... :source validator)`.

`./rocqagent-cleanup SERVER` is the server-specific cleanup path on Linux. It:

- touches the current cancel-file when a request is busy
- tries the graceful Proof General shutdown path first
- falls back to killing only the validated process roots for that server and their descendants

It does not kill other Emacs servers or unrelated Rocq processes.

For long-running checks, run `coqcheck_until` in the background from the shell
and poll the status file directly, or run `./rocqagent-health --skip-ping SERVER`.
Status reports include a `:subphase` field, so
clients can distinguish `restart=t` dependency compilation (`dune-deps`) from
actual script checking.
Status files now also record `:server-name`, `:emacs-pid`, `:socket-dir`, and `:socket-path`
so shell-side tools can distinguish a live daemon from a stale status file.

The static status file is still required even though the internal async API is
gone: the supported async pattern is to background the synchronous
`coqcheck_until` from the shell and inspect/cancel it via the status file.

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

For agent automation, you must use `./rocqagent-call SERVER ELISP` instead of the raw
`emacsclient --eval ...`. The wrapper:

- enforces one shell-side RPC at a time per Emacs server
- refuses to queue another request while `coqcheck_until` is already busy
- refuses to send a new request when other `emacsclient` processes are already
  talking to the same server
- refuses to treat a stale `:busy t` status from a dead server as a live busy request

See [skills/rocqemacs/SKILL.md](skills/rocqemacs/SKILL.md) for the full agent-facing API contract.

## Experimental features

Large proof developments sometimes keep an expensive live Coq session near the
interesting frontier, while an agent still issues `restart=t` out of caution.
If Dune reports that nothing needed recompilation, tearing down that live
session is wasted work: the checked region jumps back and the next proof query
becomes slower for no benefit.

To experiment with avoiding that, `rocqagent.el` exposes:

```elisp
rocqagent-preserve-session-on-noop-restart
```

When this flag is non-`nil`, a `restart=t` request that runs `dune rocq top`
successfully but compiles no Rocq source files will keep the existing live
session and continue with the normal incremental reload path instead of forcing
a teardown/restart.

The default is `nil`. This keeps the public API conservative. Local setups can
opt in, for example from `~/.emacs`, if preserving an already-good live session
after frivolous `restart=t` requests is more valuable than strict restart
semantics.

### Codex Dune build gate hook

The skill also includes an experimental Codex hook script:

```text
skills/rocqemacs/scripts/rocq-dune-gate
```

It blocks `dune build` / `dune b` on dirty `.v` files unless the file has had a
successful `rocqagent-call ... coqcheck_until` since its last edit.  This is a
guardrail against using a full Dune build as the first checker for files that
should have been checked incrementally through the live Emacs session.

Example project setup:

```sh
mkdir -p PROJECT_ROOT/.codex/hooks
ln -s /home/abhishek/fv-workspace/rocq-emacs-for-cli-agents/skills/rocqemacs/scripts/rocq-dune-gate \
  PROJECT_ROOT/.codex/hooks/rocq-dune-gate
```

Then add this to `PROJECT_ROOT/.codex/hooks.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "^Bash$",
        "hooks": [
          {
            "type": "command",
            "command": "ROCQ_DUNE_GATE_WORKSPACE=/absolute/path/to/PROJECT_ROOT python3 /absolute/path/to/PROJECT_ROOT/.codex/hooks/rocq-dune-gate pre",
            "timeoutSec": 10
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "^Bash$",
        "hooks": [
          {
            "type": "command",
            "command": "ROCQ_DUNE_GATE_WORKSPACE=/absolute/path/to/PROJECT_ROOT python3 /absolute/path/to/PROJECT_ROOT/.codex/hooks/rocq-dune-gate post",
            "timeoutSec": 10
          }
        ]
      }
    ]
  }
}
```

Use absolute paths in `hooks.json`.  Codex runs hook commands from the tool
invocation working directory, not from the directory containing `hooks.json`, so
relative paths can break when the agent is working in a subdirectory.

## Setup

Load `rocqagent.el` after Proof General:

```elisp
(load "/path/to/rocqagent.el")
```

Optional validation hook in `~/.emacs`:

```elisp
(defun my-rocq-validator (_filename _ctx)
  (save-excursion
    (goto-char (point-min))
    (unless (re-search-forward
             "^Set Default Goal Selector \"!\"\\.[[:space:]]*$"
             nil t)
      "Missing required line: Set Default Goal Selector \"!\".")))

(add-hook 'rocqagent-before-refresh-check-functions
          #'my-rocq-validator)
```

What this example does:

- it enforces that every checked file contains the line `Set Default Goal Selector "!".`
- the check runs before `coqcheck_until` starts reverting, restarting, or sending commands to Rocq
- if the line is missing, the API returns a validator error immediately

How to enable it:

- add the snippet above to `~/.emacs`
- restart the Emacs daemon, or evaluate the new definitions in the running Emacs session

## Making the skill visible to Codex

Project-local skill link:

```sh
mkdir -p PROJECT_ROOT/.agents/skills
ln -s /home/abhishek/fv-workspace/rocq-emacs-for-cli-agents/skills/rocqemacs \
  PROJECT_ROOT/.agents/skills/rocqemacs
```

Global skill link:

```sh
mkdir -p ~/.codex/skills
ln -s /home/abhishek/fv-workspace/rocq-emacs-for-cli-agents/skills/rocqemacs \
  ~/.codex/skills/rocqemacs
```

Rocq Project Requirements:

- This API uses dune to build dependencies of the current file when the agent requests a fresh build. so a dune build system is needed.
- A _CoqProject is also needed by proof-general/company-coq to pass the right flags (e.g. -Q) to Coq. There are tools to build _CoqProject automatically from dune: e.g. see SkyLabsAI repos.
- Point agents to [skills/rocqemacs/SKILL.md](skills/rocqemacs/SKILL.md)
