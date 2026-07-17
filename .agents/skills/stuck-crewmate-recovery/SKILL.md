---
name: stuck-crewmate-recovery
description: Agent-only playbook for stuck firstmate direct reports. Use after a stale wake, looping pane, repeated confusion, an answered-by-brief question, an unresponsive crewmate, a usage-blocked crew, or a failed steer. Escalates from peek, to one-line steer, to harness-specific interrupt, to relaunch with progress, to failed status; a usage-blocked crew is parked and auto-retried at reset, never relaunched.
user-invocable: false
metadata:
  internal: true
---

# stuck-crewmate-recovery

Use this playbook when a direct report is stale, looping, repeatedly confused, asking a question its brief already answers, unresponsive, usage-blocked, or when a steer failed to land.

Load `harness-adapters` before sending an interrupt, exit command, resume command, or harness-specific skill invocation.
The target window's harness is recorded as `harness=` in `state/<id>.meta`.

## Usage-blocked: park, don't relaunch

When `bin/fm-crew-state.sh <id>` reports `state: usage-blocked` (the Claude account usage cap: a pane "session limit · resets <time>" dialog, and/or its no-mistakes review/test sub-agents crashing with `claude exited: exit status 1`), the work is intact and the cap is account-wide, so a relaunch only inherits the same cap and discards the crew's loaded context + repro.
Do NOT relaunch, and do NOT keep re-nudging into a still-capped window.
Instead park and auto-retry at reset:

1. `bin/fm-usage-park.sh <id>` records the crew as parked and (re)writes ONE shared poll (`state/usage-retry.check.sh`) that fires a single wake once the reset time has passed.
   Pass the reset clock explicitly (`bin/fm-usage-park.sh <id> "5:30pm"`) if the crew-state detail did not capture one; otherwise it reads the reset from `fm-crew-state.sh` and, failing that, estimates now + 5h.
2. Leave the crew's pane and worktree untouched.
   When the reset `check:` wake arrives, re-nudge each parked crew in place to resume (for claude, a plain resume nudge via `bin/fm-send.sh`, consulting `harness-adapters` for the key); the crew keeps its context and repro.
3. Account-wide, surface it to the captain ONCE with the reset time, not once per crew.
   `state/.usage-reset-epoch` records the active window; hold new Claude dispatches until it passes rather than spawning fresh claude crews into the same cap.
4. Failover option for carry-over-able work: dispatch a NEW crew for the same task on a non-Claude harness (codex/grok) instead of waiting, per the active `config/crew-dispatch.json`.
   Weigh this against losing the parked crew's in-progress context; prefer park-and-retry when the crew is close to done.

Before checking the actual window state, verify the current clock against the reset time (`TZ=America/Chicago date`): a "resets 5:30pm" banner sitting stale in a pane may be from a window that already reopened.

## Everything else

Escalate in order:

1. Peek the pane.
2. If the crewmate is waiting on a question its brief already answers, answer in one line via `bin/fm-send.sh`.
3. If the crewmate is confused or looping, interrupt with the adapter's interrupt key, then redirect with one corrective line.
   For example, for a single-Escape adapter: `bin/fm-send.sh <window> --key Escape`.
4. If the crewmate is genuinely wedged after redirection, exit the agent with the adapter's exit command and relaunch with the same brief plus a `progress so far` note appended to it.
   Genuine wedging means looping, unresponsive, repeating the same obstacle, or truly dead.
   A low context reading is not wedging; modern harnesses auto-compact and keep going.
   The worktree and commits persist, so relaunch is cheap.
5. If a second relaunch fails too, write `failed` to the backlog and tell the captain with evidence.
