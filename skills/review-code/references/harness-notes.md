# Harness notes — the collaboration mechanics behind Step 5

The skill body is harness-neutral. This file holds what differs per harness. Verified against vendor documentation in November 2026; items tagged **[V]** are version-fragile and must be re-verified on your build before the first peer run. Shared by review-code and review-plan.

## Capability check (Step 5a) — decide by harness identity, then confirm

The question is one thing only: **can an agent you spawn send a message to a sibling you also spawned?** The lead cannot see a child's tool list, and `SendMessage` in the lead's own list proves lead→child, not child→child. So:

1. **Harness identity.** Not Claude Code → **mediated**, no further inspection (all other harnesses below are hub-and-spoke as of this writing).
2. **Claude Code: tools.** `SendMessage` appears in your tool list (loaded or deferred) → candidate for peer.
3. **Claude Code: one-time probe per install.** Spawn two trivial agents in one message; tell A to message B by the id or name you give it and B to reply; confirm B received it. Record the result and the build number as a comment beside `COLLAB_MODE` in your skill's Configuration block (that is your file; this one is the shipped reference). Probe passes → set `COLLAB_MODE=peer`; fails → `COLLAB_MODE=mediated`. Either way the probe is not repeated every run; re-run it after a harness upgrade.
4. **Roster delivery.** If your `Agent` tool accepts a `name` parameter **[V]**, pre-fill the roster in each prompt. If it does not (ids are returned only after spawn), spawn first, then send every reviewer one message with the full roster of ids and domains; the reviewer prompt says to wait for that message before any DM. Either way the roster lists exactly the agents that carry the peer block.

| Harness | Parallel subagents | Sibling-to-sibling messaging | Mode |
|---|---|---|---|
| Claude Code | yes | yes — spawned agents can be addressed with `SendMessage` by id or name **[V]**; the broader "agent teams" feature (shared task list, teammates as separate sessions) is experimental and flag-gated and is not required | **peer** after the probe |
| OpenAI Codex CLI | yes | not documented; parent→child only (`spawn_agent`, `send_input`, `wait_agent`). A message-board subsystem exists behind feature flags — re-evaluate when it ships | **mediated** |
| GitHub Copilot CLI | yes (`/fleet`) | no — orchestrator dispatches waves | **mediated** |
| Cursor | yes, one nesting level | no — "returns its result to the parent agent" | **mediated** |
| Gemini CLI | yes | no — "subagents cannot call other subagents" | **mediated** |

All five read `SKILL.md` and custom agent definitions, so roster and detection table transfer; only Step 5's mechanism changes.

## Claude Code — peer mode mechanics

- **Lead must be the main session.** Spawned agents cannot spawn peers of their own; if this skill is invoked from inside a subagent, peer mode is impossible — use mediated.
- **Spawn:** every reviewer in ONE message. Background execution is the default on current builds; if your `Agent` schema has a `run_in_background` flag **[V]**, set it. Pass a `LOCAL EXECUTION` block in every prompt that can run commands: a subagent can't see how many siblings are running, and six reviewers each starting a project-wide typecheck has put a machine into swap.
- **Permissions:** a reviewer that runs commands (grep, git log) needs a mode that auto-approves commands, not only file edits **[V]** (on Claude Code, `bypassPermissions`; `acceptEdits` approves Writes but not Bash, and a background reviewer then **stalls silently on its first command with no output and no completion** — the exact shape of a review hung with reviewers "pending" forever). Your repo's guardrails (hooks, protected files) still apply; only the per-command prompt is removed.
- **Agent type:** a custom agent definition whose `tools` list lacks `ToolSearch` cannot load `SendMessage` and silently degrades to isolated. Grant `ToolSearch` to reviewer agents, or spawn `general-purpose` agents and inject the domain lens through the prompt's `<DOMAIN>` slot (the detection table still decides which lenses launch).
- **Step 0 in every peer prompt:** `ToolSearch({query: "select:SendMessage"})` **[V]**. A no-op where it's already loaded; load-bearing on builds that didn't auto-load it, where omitting it made peer DM impossible and the failure was silent.
- **Peer DMs are invisible in your chat.** Only messages addressed to you show up. Dialogue lives in each recipient's inbox under the session's team directory (`~/.claude/teams/session-*/inboxes/*.json` **[V]** — `ls` it before the first run; resolve by glob, never a hardcoded name). Snapshot it to `SCRATCH_DIR/inbox-snapshot/` before retiring anyone (Step 7).
- **Completion:** the `REVIEW-COMPLETE <name> <RUN_ID>` marker as each file's last line, plus a bounded watcher: a background `until` loop over `SCRATCH_DIR/findings/` that exits when every expected marker is present or `TIMEBOX` elapses. It is a wait on files, not a timer that re-invokes the skill — a wake-up that re-fires the skill restarts the review. A reviewer's "done" message is a hint; the marker is proof.
- **Retire:** `SendMessage({to: "<id>", message: {type: "shutdown_request", reason: "…"}})` **[V]** to each reviewer individually; wait 60–120 s for acks (per-reviewer usage data arrives with them). A reviewer that never acks can be left; session-end cleanup removes it.
- **Agent teams flag:** with `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` **[V]**, spawned agents also get a shared task list. Peer mode works either way.

## Mediated mode on hub-and-spoke harnesses

- **Round 1:** ordinary parallel dispatch, every reviewer in one message, each writing its own findings file ending in `<!-- REVIEW-COMPLETE <name> <RUN_ID> R1 -->`.
- **Before round 2:** copy `findings/` to `findings/round1/` (read-only). The diff between round 1 and round 2 files is your inbox — it is how you detect a round-1 BLOCK silently rewritten, which is the mediated form of sycophantic concession.
- **Round 2:** each reviewer gets the others' BLOCK and REQUEST_CHANGES findings attributed **by domain, not by agent name**, and the round-2 block from the reviewer prompt. Where the harness can resume a finished agent (Claude Code: `SendMessage` to it), resume it with a budget of about 15 more calls. Where it can't (Codex `send_input` targets live agents only; Copilot, Cursor, Gemini return and exit), spawn fresh with the reviewer's own round-1 file attached, scope restricted to the files the attached findings cite, budget about 20 calls. Marker: `<!-- REVIEW-COMPLETE <name> <RUN_ID> R2 -->`. `EXPECT` therefore holds `:R1` and `:R2` entries per domain and test reviewer and `zero-context:R1` (matching rule in `sentinels.md`).
- **Lead's extra duties (Step 7):** adjudicate every DISPUTE and ESCALATE yourself with both citations in hand (round 2 is terminal; there is no round 3 unless you dispatch one); treat zero DISPUTEs group-wide, or a CONFIRM whose citation merely restates the original, as a convergence signal; before declaring DISSENT, one targeted re-dispatch to the two parties with both citations is allowed.
- **`TIMEBOX`** is the total for both rounds; round 2 gets the remainder, minimum 40%.
- **What you lose vs peer mode:** mid-review redirection (a peer changes what it reads because of a DM; here that happens one round later), SUGGEST-tier cross-domain hints (only BLOCK and REQUEST_CHANGES propagate), and live back-and-forth (one exchange, through you). Calibrate your own yield before deciding the difference matters for your repo.

## If the capability check is wrong

A mode mismatch fails visibly: in peer mode with no messaging tool, reviewers can't load it at Step 0 and say so in their findings — switch to mediated for the rest of this review (run round 2 now) and fix `COLLAB_MODE`. In mediated mode on a harness that does have messaging, you've paid one extra round for nothing worse than an unused feature.
