# Process argument transport

## Constraint and decision

SentinelOne on the verified fleet host inspects each process argument as a possible relative path and kills the process when the working directory, one slash, and that argument exceed 1,024 bytes.

The boundary was reproduced on 2026-08-18 from an 88-byte working directory, where a 935-byte argument survived and a 936-byte argument was killed before the process initialized.

Firstmate therefore gives every supported harness the same imperative instruction, `Read and follow the brief at '<absolute-path>'.`, instead of expanding the brief contents into a process argument.

The path is quoted inside the instruction text the agent reads, so a sentence-final period cannot be mistaken for part of the filename, and the shipped string is byte-for-byte the string each adapter was verified against below.

The runtime safety budget is 896 bytes for the working directory, one slash, and one argument, which leaves 128 bytes below the observed failure boundary.

Every place the budget is computed measures the actual string rather than a modelled length, so the quote characters are already accounted for: the launch guard measures the assembled launch command, the brief-prompt guard measures the prompt from the worktree the harness will run in, and the away-mode digest bounds itself against `fm_backend_argv_entry_budget`.

The disposable verification fixture used on 2026-08-19 had an 89-byte working directory, and its 130-byte verification prompt produced a 220-byte candidate.

The automated launch guard in `tests/fm-spawn-dispatch-profile.test.sh:110-189` constructs 8,192-byte ship and secondmate briefs for all five adapters, rejects any launch that still contains `$(cat`, caps the backend launch candidate at 896 bytes, executes the command against an argument-recording harness, and caps every harness argument at 512 bytes.

The refusal path is covered by `tests/fm-spawn-dispatch-profile.test.sh:195-217`, which drives an over-budget launch and asserts the spawn refuses before any endpoint, worktree, or `state/<id>.meta` exists, so a guard firing can never leave an orphaned task behind.

## Adapter verification

The verification brief contained the following exact text.

```text
Read this file completely.
Respond with exactly FIRSTMATE_BRIEF_PATH_OK and nothing else.
Do not use tools or modify files.
Exit after responding.
```

Claude Code 2.1.227 was verified on 2026-08-19 with the following command.

```sh
CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions --print "Read and follow the brief at '/Users/andrew/.no-mistakes/worktrees/3334203e60eb/01M0DJ2FG0H4RDSQD2PDQ0YZ9R/.verify-argv/brief.md'."
```

Claude read the named file and returned exactly `FIRSTMATE_BRIEF_PATH_OK` with exit status zero after its normal local-settings warnings.

Codex CLI 0.146.1 was verified on 2026-08-19 with the following command.

```sh
codex exec --dangerously-bypass-approvals-and-sandbox -C '/Users/andrew/.no-mistakes/worktrees/3334203e60eb/01M0DJ2FG0H4RDSQD2PDQ0YZ9R/.verify-argv' "Read and follow the brief at '/Users/andrew/.no-mistakes/worktrees/3334203e60eb/01M0DJ2FG0H4RDSQD2PDQ0YZ9R/.verify-argv/brief.md'."
```

Codex read `brief.md` with `sed`, reported that an unrelated inherited skill path was missing from the fixture, and returned exactly `FIRSTMATE_BRIEF_PATH_OK` with exit status zero.

OpenCode 1.15.13 was verified on 2026-08-19 from the fixture directory with the following command.

```sh
OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"}}' opencode run "Read and follow the brief at '/Users/andrew/.no-mistakes/worktrees/3334203e60eb/01M0DJ2FG0H4RDSQD2PDQ0YZ9R/.verify-argv/brief.md'."
```

OpenCode reported `Read brief.md`, returned exactly `FIRSTMATE_BRIEF_PATH_OK`, and exited with status zero.

Pi could not be verified because no `pi` executable was installed on the verification host on 2026-08-19.

Grok could not be verified because no `grok` executable was installed on the verification host on 2026-08-19.

The path-instruction approach succeeded for every installed adapter, so no adapter-specific standard-input transport was needed.

## Argument audit

The ship, scout, and secondmate launch templates in `bin/fm-spawn.sh:296-334` previously expanded a whole brief into one harness argument for Claude, Codex, OpenCode, Pi, and Grok.

Those templates now share the short path instruction assembled at `bin/fm-spawn.sh:652-692`, and the existing flags, environment prefixes, autonomy switches, and turn-end hooks are unchanged.

That assembly and its launch guard run before the runtime endpoint, the worktree, the task temp root, the turn-end hook files, and `state/<id>.meta` exist, because a guard that refused later would exit leaving a dead task that recovery reads as in-flight work.

The one check that cannot be hoisted that far is the brief prompt measured from a pooled treehouse or Orca worktree, which by construction cannot exist before the endpoint; it runs at `bin/fm-spawn.sh:871`, the first point where the worktree path is final and still before any of the state above is created.

The raw-command escape hatch at `bin/fm-spawn.sh:337-341` remains caller supplied and can already arrive as an argument to `fm-spawn.sh`, so the operating rule in `AGENTS.md` limits it to a short wrapper command whose long content lives in a file.

The tmux launch and send paths at `bin/backends/tmux.sh:92-101` and `bin/fm-tmux-lib.sh:188-192` pass text to `tmux send-keys` as one argument.

The herdr launch and send paths at `bin/backends/herdr.sh:538-549` and `bin/backends/herdr.sh:693-705` pass text to `herdr` as one argument.

The zellij launch and send paths at `bin/backends/zellij.sh:431-471` and `bin/backends/zellij.sh:504-512` pass text to `zellij` as one argument.

The Orca launch and send paths at `bin/backends/orca.sh:162-171` and `bin/backends/orca.sh:322-334` pass text to `orca` as one argument.

The cmux launch and send paths at `bin/backends/cmux.sh:467-469` and `bin/backends/cmux.sh:583-595` pass text to `cmux` as one argument.

All five backends receive generated launch text through `bin/fm-spawn.sh:1047`, bounded by the 896-byte guard at `bin/fm-spawn.sh:680` before any resource for the task exists.

All five backends receive interactive text through `bin/fm-backend.sh:526-542`, where the same runtime guard returns `send-failed` before invoking the backend command.

The public `bin/fm-send.sh:107` path is not direct terminal typing because the text first arrives as an argument to `fm-send.sh` and then reaches the selected backend CLI as another argument.

The existing operating rule limits `fm-send.sh` to short single-line steering, and the shared backend guard now also refuses an unsafe outbound backend argument, although it cannot protect a caller that has already launched `fm-send.sh` with an oversized argument.

The away-mode escalation aggregate at `bin/fm-supervise-daemon.sh:575-616` grows with the buffered events before it reaches `fm_backend_send_text_submit` at `bin/fm-supervise-daemon.sh:825`.

It is bounded at composition time against `fm_backend_argv_entry_budget` rather than at the transport boundary: an oversized buffer delivers its newest items plus a `+N earlier escalation(s)` pointer, and the summarised items are written to the daemon log as the buffer clears.

Leaving that aggregate to the transport guard would have been a silent regression rather than a safety net, because the buffer is only cleared on a confirmed inject, so one oversized digest would have refused the same content on every later flush and an away captain would have stopped hearing about problems entirely.

That bounded-delivery contract is pinned by `tests/fm-daemon.test.sh:276-303`, which fails if an oversized buffer produces a refusal instead of a bounded, cleared delivery.

The project-name aggregate in `bin/fm-home-seed.sh:737-765` previously crossed into `awk` through one `-v` argument and was unbounded by the number of selected projects.

It now crosses through a `mktemp` file the helper owns and removes, while `awk` receives only the bounded file path.

The generated X-mode poll shim at `bin/fm-bootstrap.sh:304-313` executes only the fixed `fm-x-poll.sh` path, and the generated watcher cadence file contains only a fixed numeric export.

Every task check is launched by `bin/fm-watch.sh:322-330` as `bash <check-path>`, so the script contents never become an argument.

The generated PR check at `bin/fm-pr-check.sh:76-79` later passes one GitHub PR URL to `gh`, which is bounded by the URL and repository naming contracts rather than by file contents.

The generated usage-reset check at `bin/fm-usage-park.sh:114-133` reads its parked-task file at execution time and uses the aggregate only in a shell builtin, while the watcher still launches only the script path.

The generated Grok turn-end hook at `bin/fm-spawn.sh:946-975` reads one token file and passes the resulting filesystem path only to `touch`, so it does not embed a whole file or an unbounded aggregate in a process argument.

The X-mode image and reply paths at `bin/fm-x-lib.sh:204-288` stream content through standard input, `--slurpfile`, header files, and `curl --data-binary @file`, so whole payloads do not enter process arguments.

The reply CLI at `bin/fm-x-reply.sh:151-165` still accepts a direct text argument for short callers, but the operational `fmx-respond` skill requires `--text-file` or standard input and `bin/fm-x-followup.sh:193-195` forwards only those safe forms.

The PR-body checker and sanitizer read the body into shell memory, send it to filters through standard input, and hand any edited body to GitHub through `--body-file`, so a whole PR body does not enter a child-process argument.

No other generated script or whole-file command substitution in `bin/` passes file contents to a child process as one argument.
