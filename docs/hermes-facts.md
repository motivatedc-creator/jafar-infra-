# Hermes facts

Answers to the build plan's verification gates (V1-V10) plus the rebuild
questions (V11-V15). Researched by Jafar on 2026-09-27 from the official
Hermes Agent docs and source repo; **LOCAL** = also confirmed on the server.

Scoring rule (from the plan): an answer counts as YES only with a URL or a
LOCAL confirmation. UNVERIFIED is treated as NO.

| Q | Answer | Source | LOCAL |
|---|---|---|---|
| V1 Skills | User skills live at `~/.hermes/skills/<category>/<skill>/SKILL.md`: YAML frontmatter between `---` markers, then a non-empty Markdown body; `name` and `description` are required. | https://hermes-agent.nousresearch.com/docs/user-guide/features/skills | yes |
| V2 MCP | YES. Local stdio and remote HTTP servers. `mcp_servers: {local: {command: "npx", args: ["-y", "pkg"]}, remote: {url: "https://mcp.example.com/mcp", headers: {Authorization: "Bearer ${MCP_TOKEN}"}}}` | https://hermes-agent.nousresearch.com/docs/reference/mcp-config-reference | no |
| V3 Fallback | YES. Top-level `fallback_providers` list, each entry `provider` + `model`, tried in order. `fallback_providers: [{provider: openrouter, model: anthropic/claude-sonnet-4}, {provider: openai-api, model: gpt-5.4}]` | https://hermes-agent.nousresearch.com/docs/user-guide/features/fallback-providers | no |
| V4 One-shot CLI | YES. `hermes chat --oneshot -q "your prompt"` | https://hermes-agent.nousresearch.com/docs/user-guide/sessions | no |
| V5 Update / pin | Update: `hermes update`. The source installer accepts `--commit SHA` for a pinned install; a source install can be rolled back manually to an earlier revision (older code may not read data migrated by newer code). The updater tracks its channel (default `main`); no persistent version lock verified. | https://hermes-agent.nousresearch.com/docs/getting-started/updating ; https://github.com/NousResearch/hermes-agent/blob/main/scripts/install.sh | no |
| V6 Cron | `hermes cron create`, or the cron tool in chat. Stored in `~/.hermes/cron/jobs.json` (not `config.yaml`). | https://hermes-agent.nousresearch.com/docs/user-guide/features/cron ; https://hermes-agent.nousresearch.com/docs/developer-guide/cron-internals | no |
| V7 Attachments | YES. Photon downloads inbound attachments and passes cached media to the agent; voice notes can be transcribed. Over 20 MB or on read failure it may pass a text marker instead. | https://github.com/NousResearch/hermes-agent/blob/main/plugins/platforms/photon/README.md | no |
| V8 Command rules | YES. Permanent approvals: top-level `command_allowlist`; user denylist: `approvals.deny`. `approvals: {deny: ["git push --force*"]}`, `command_allowlist: ["systemctl"]` | https://hermes-agent.nousresearch.com/docs/user-guide/security | no |
| V9 Credential files | **Partial.** Photon: `/home/dietpi/.hermes/.env` plus one more file. Codex/ChatGPT OAuth state: one Hermes file. Optional Codex CLI source: `/home/dietpi/.codex/auth.json` (existence not checked). Both Hermes file paths arrived **blank** in two separate replies (credential-looking paths appear to be stripped between the server and the phone), so they are **UNVERIFIED**. Neither `hermes auth add openai-codex` nor `hermes photon setup` writes `config.yaml`. | https://hermes-agent.nousresearch.com/docs/integrations/providers ; https://hermes-agent.nousresearch.com/docs/user-guide/messaging/photon ; https://github.com/NousResearch/hermes-agent/blob/main/hermes_cli/auth.py ; https://github.com/NousResearch/hermes-agent/blob/main/plugins/platforms/photon/auth.py | yes (the two Hermes files exist) |
| V10 Logs | `~/.hermes/logs/` (`agent.log`, `errors.log`, `gateway.log`). Sample: `2026-09-26 23:25:42,849 INFO gateway.run: Gateway housekeeping started (interval=60s)` | https://hermes-agent.nousresearch.com/docs/user-guide/configuration | yes |
| V11 Installer | `curl -fsSL https://hermes-agent.nousresearch.com/install.sh \| bash`. Per-user, no sudo (optional Playwright system deps may need it). No prompts with `--non-interactive`; `--skip-setup` skips the setup wizard. | https://hermes-agent.nousresearch.com/docs/getting-started/installation ; https://github.com/NousResearch/hermes-agent/blob/main/scripts/install.sh | no |
| V12 Gateway service | `hermes gateway install` then `hermes gateway start`. On Linux, `sudo loginctl enable-linger "$USER"` keeps it running after logout. | https://hermes-agent.nousresearch.com/docs/user-guide/messaging/ | no (unit file observed, see CONTEXT.md) |
| V13 Re-auth order | 1 `hermes auth add openai-codex` (device-code login) 2 `hermes photon setup --phone <E.164 number>` (Photon login; also installs sidecar dependencies) 3 `hermes gateway install` 4 `hermes gateway start` | https://hermes-agent.nousresearch.com/docs/integrations/providers ; https://hermes-agent.nousresearch.com/docs/user-guide/messaging/photon ; https://hermes-agent.nousresearch.com/docs/user-guide/messaging/ | no |
| V14 Outside ~/.hermes | Code `~/.hermes/hermes-agent`, command `~/.local/bin/hermes`. Needs git, curl, xz-utils; the installer provisions Python, Node, ripgrep, ffmpeg. Python version: docs conflict (3.11 vs 3.14), UNVERIFIED. | https://hermes-agent.nousresearch.com/docs/getting-started/installation ; https://hermes-agent.nousresearch.com/docs/user-guide/switching-to-source | yes |
| V15 Restore as-is | UNVERIFIED as a blanket claim. `state.db` schema reconciliation runs when it is opened. For config: `hermes config check`, and `hermes config migrate` if options are missing. No required doctor step found. | https://github.com/NousResearch/hermes-agent/blob/main/hermes_state_schema.py ; https://hermes-agent.nousresearch.com/docs/user-guide/configuration | no |
| State on a fresh install | The installer alone (`--non-interactive --skip-setup`) creates no `state.db`; SQLite creates it when the gateway first opens SessionDB, and `sessions` has 0 rows until the first conversation. | https://github.com/NousResearch/hermes-agent/blob/main/scripts/install.sh ; https://github.com/NousResearch/hermes-agent/blob/main/gateway/session.py ; https://github.com/NousResearch/hermes-agent/blob/main/hermes_state.py | no |

## Gate decisions (from the plan's table)

| Gate | Result | Branch taken |
|---|---|---|
| V1 | YES (LOCAL) | native skill format |
| V2 | YES | build the 3 MCP servers |
| V3 | YES | native `fallback_providers` |
| V4 | YES | evals call `hermes chat --oneshot` |
| V5 | YES, with caveats | auto-update with rollback via `--commit` reinstall + restore |
| V6 | YES | `hermes cron create` / `jobs.json` |
| V7 | YES | build #16 only if the 0.9 voice gate says so |
| V8 | YES | Tier B: `approvals.deny` / `command_allowlist` |
| V9 | partial, treat as NO | exclude by pattern (`*auth*`, `*token*`, `*credential*`) and list re-auth steps |
| V10 | YES (LOCAL) | parse the documented format |
