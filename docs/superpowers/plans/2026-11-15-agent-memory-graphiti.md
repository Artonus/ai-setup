# Agent Memory (Graphiti on naboo) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Trilium-backed agent memory (`memory-search` MCP plus the "Memory (Trilium)" rules) with a self-hosted Graphiti knowledge graph on FalkorDB, running on the homelab server `naboo` behind Traefik and reachable only over Tailscale at `agent-memory.homelab.artonus.net`, used by Claude Code, OpenCode and Kilo.

**Architecture:** One Docker Compose stack on naboo runs FalkorDB and the Graphiti MCP server (streamable HTTP, `/mcp/`). Only Traefik is exposed; the MCP server has no authentication, so network reachability (Tailscale) is the access control. The agents get the server as an `agent-memory` MCP entry in each harness config and a rewritten memory section in `shared/AGENTS.md`. Facts live in two graph namespaces (`group_id`): `personal` and `work`. Existing `#memory` notes are migrated once, then `memory-search` is removed.

**Tech Stack:** Graphiti MCP server (`getzep/graphiti`, `mcp_server/`), FalkorDB, Docker Compose, Traefik, Tailscale, a `uv` Python script for the smoke test, bash tests in `tests/`, `jq`.

**Spec:** None. The design was decided in the conversation of 2026-11-15; the decisions are under Global Constraints.

## Global Constraints

- Hostname: `agent-memory.homelab.artonus.net`, served by Traefik on naboo over HTTPS. It must resolve and answer only from the tailnet.
- The Graphiti MCP endpoint is `https://agent-memory.homelab.artonus.net/mcp/` (trailing slash). Its health check is `/health`.
- Public repo: the hostname, URLs and keys never appear in committed files. Deploy files read `AGENT_MEMORY_HOST` from `.env`; clients read `AGENT_MEMORY_URL` from the environment (`{env:AGENT_MEMORY_URL}` in OpenCode and Kilo, `${AGENT_MEMORY_URL}` in `claude/mcp.json`).
- No ports of FalkorDB (6379, 3000) or of the MCP server (8000) are published on the host. Only the MCP container joins the Traefik network.
- Namespaces: `personal` and `work`. Entities are not shared across groups, on purpose. The work overlay sets `work` as its default; the public setup defaults to `personal`.
- The LLM and embedder provider for extraction is chosen in Task 0 and set only through `.env` on naboo. Work data must not go to a provider the user has not approved for it.
- Pin the Graphiti and FalkorDB images to a tag or digest recorded in Task 0. Never `latest`.
- `.env` is gitignored; `deploy/agent-memory/.env.example` lists names only.
- Trilium stays configured as a notes tool (`trilium-notes` skill, `meeting-notes` agent). Only its use as agent memory ends.
- Config changes go through the repo and `install.sh` (`modifying-ai-setup` skill), with `AI_SETUP_OVERLAY` set on every install.
- Commit messages are conventional commits with no `Co-Authored-By` trailer and no "Generated with" line.

## Review Focus

- A new fact that contradicts an older one ("service X is owned by team A" then "by team B") must leave only the new fact valid in a current-facts search, with the old one still readable by date. (Task 2)
- A fact written to `work` must never show up in a `personal` search, and the reverse. (Task 2)
- naboo down, Tailscale off, or a DNS failure must not hang or break an agent session: the MCP entry fails to connect and the agent carries on, saying memory is unavailable. (Task 4)
- Reaching the hostname from outside the tailnet, or any direct connection to 6379, 3000 or 8000 on naboo's LAN address, must fail. (Task 1)
- Adding the same episode twice must not create duplicate facts or duplicate entities. (Task 2)

---

### Task 0: Discover naboo and decide providers (manual, no commits)

Findings go into `deploy/agent-memory/NOTES.md` only if useful later; they decide the values Tasks 1 and 2 use.

- [ ] **Step 1: Inspect naboo.** Over SSH or Tailscale SSH: record the Docker and Compose versions, where existing stacks live (path, naming), the Traefik setup (Docker-labels provider or file provider, entrypoint name, certificate resolver, the external network name services join, any existing middlewares), how the `homelab.artonus.net` DNS record is served (which IP it points to), and how persistent volumes are backed up.
- [ ] **Step 2: Read the upstream files.** Open `mcp_server/` in `getzep/graphiti` at the current release. Record: the compose file actually used for FalkorDB, the image name and a pinned tag or digest, the YAML config file name and keys, the exact tool parameter names for group selection (`group_id` or `group_ids`), and whether the container runs FalkorDB itself or needs a separate one. The README gave conflicting compose file names and a doubtful default model name, so trust the repo files over the README.
- [ ] **Step 3: Choose providers.** Decide the extraction LLM and the embedder with the user: whether work data may go to a hosted LLM or must stay on a local Ollama model, and whether embeddings run locally (Sentence Transformers) or through an API. Record the model names.
- [ ] **Step 4: Check source IPs.** Note whether Traefik sees the real Tailscale source address (`100.64.0.0/10`) or a Docker bridge address. This decides whether the optional `ipAllowList` middleware in Task 1 is usable.

### Task 1: Deploy the stack on naboo

**Files:**
- Create: `deploy/agent-memory/docker-compose.yml`
- Create: `deploy/agent-memory/config.yaml` (Graphiti server config: provider names, model names, database provider `falkordb`; no keys)
- Create: `deploy/agent-memory/.env.example`
- Create: `deploy/agent-memory/README.md` (deploy, update, back up, roll back; 20 lines)
- Modify: `.gitignore` (add `deploy/agent-memory/.env`)
- Test: `tests/test_deploy.sh`

**Interfaces:**
- Consumes: the image tags, config keys and Traefik facts from Task 0.
- Produces: a running service answering `GET https://agent-memory.homelab.artonus.net/health` from the tailnet. `.env.example` names: `AGENT_MEMORY_HOST`, `LLM_API_KEY` (the provider's real variable name from Task 0), `EMBEDDER_API_KEY` (only if an API embedder is chosen), `SEMAPHORE_LIMIT`, `FALKORDB_PASSWORD`. Task 2 uses the URL; Task 3 uses the same URL through `AGENT_MEMORY_URL`.

- [ ] **Step 1: Write the failing test** `tests/test_deploy.sh`, in the style of `tests/test_layout.sh`:
  - `test_deploy_publishes_no_ports`: `docker-compose.yml` has no `ports:` key at all (parse with `python3 -c 'import yaml'` is not available, so use `grep -nE '^\s+ports:'` and assert no match).
  - `test_deploy_has_no_literal_hostname_or_keys`: no file under `deploy/agent-memory/` contains `artonus.net` or a string matching `sk-[A-Za-z0-9]{10,}`.
  - `test_deploy_pins_images`: every `image:` line contains `:` followed by a tag other than `latest`, or `@sha256:`.
  - `test_deploy_env_is_ignored`: `git check-ignore deploy/agent-memory/.env` exits 0.
  - `test_deploy_env_example_names_only`: every non-comment line in `.env.example` matches `^[A-Z_]+=$`.
- [ ] **Step 2: Run** `bash tests/run.sh` and confirm the new tests fail.
- [ ] **Step 3: Write the compose file and config.** Base it on the upstream FalkorDB compose from Task 0. Required differences: no published ports; persistent volume for FalkorDB with append-only persistence on; `restart: unless-stopped`; a healthcheck on `/health`; the MCP service joins the Traefik network and carries the Traefik router for `Host(\`${AGENT_MEMORY_HOST}\`)` with TLS through the resolver found in Task 0; `SEMAPHORE_LIMIT` taken from `.env` with a default of `3`; the `group_id` default `personal`. If Task 0 step 4 found that real Tailscale source IPs reach Traefik, add an `ipAllowList` middleware for `100.64.0.0/10`; otherwise skip it and rely on DNS plus Tailscale.
- [ ] **Step 4: Run the tests** and confirm they pass.
- [ ] **Step 5: Deploy.** Copy `deploy/agent-memory/` to naboo's stack directory, create `.env` there from `.env.example` with real values (mode 600), then `docker compose up -d`. Expected: `docker compose ps` shows both services healthy.
- [ ] **Step 6: Verify reachability.** From this Mac on the tailnet: `curl -fsS https://agent-memory.homelab.artonus.net/health` returns success. From a machine off the tailnet (phone on mobile data, or Tailscale turned off): the same command fails. From a LAN machine that is not on the tailnet: `nc -zv <naboo-lan-ip> 6379`, `3000` and `8000` all fail.
- [ ] **Step 7: Commit** `deploy/agent-memory/`, `.gitignore` and `tests/test_deploy.sh` as `feat(memory): add Graphiti and FalkorDB deployment for naboo`.

### Task 2: Smoke test that proves the memory behaves

**Files:**
- Create: `tools/bin/agent-memory-smoke` (executable `uv` script, same header style as `tools/bin/memory-search-mcp`, depends on `mcp>=1.9,<2`)
- Test: run against the live server; plus `test_smoke_script_is_executable_and_has_help` in `tests/test_tools.sh`

**Interfaces:**
- Consumes: `AGENT_MEMORY_URL` from the environment; the tool names `add_memory`, `search_memory_facts`, `search_nodes`, `get_episodes`, `delete_episode`, `clear_graph` and the group parameter name found in Task 0.
- Produces: `agent-memory-smoke [--url URL]` exits 0 when every check passes and prints one `PASS` or `FAIL` line per check. It writes only to groups named `smoke-a` and `smoke-b`, and clears both before and after.

- [ ] **Step 1: Write the failing check list** in the script as named functions that each return pass or fail, and run it against the live server so each fails or errors before logic exists:
  - `check_health`: `/health` answers.
  - `check_write_then_find`: add the episode "The billing-service retry job is owned by team Alpha." to `smoke-a`, wait until `get_episodes` shows it processed (poll up to 60 s), then `search_memory_facts("who owns the billing-service retry job")` returns a fact mentioning Alpha.
  - `check_contradiction_invalidates`: add "As of today the billing-service retry job is owned by team Beta." to `smoke-a`, wait, then a current-facts search mentions Beta and does not return the Alpha fact as currently valid; a search that includes history (date range or the invalidated flag, per Task 0) still shows Alpha.
  - `check_group_isolation`: the same search against `smoke-b` returns no facts.
  - `check_duplicate_episode_is_idempotent`: add the Beta episode a second time, wait, and the count of facts mentioning Beta is unchanged.
- [ ] **Step 2: Run** `AGENT_MEMORY_URL=https://agent-memory.homelab.artonus.net/mcp/ agent-memory-smoke` and confirm failures where Graphiti behaviour differs from the checks. Any check that fails against the real server means the server config (Task 1) or the model choice (Task 0) is wrong, not the check: fix the deployment, not the expectation.
- [ ] **Step 3: Implement** each check with the MCP Python client over streamable HTTP. Poll for processing instead of sleeping a fixed time, since extraction is asynchronous.
- [ ] **Step 4: Run** the smoke test until all checks pass, and record the extraction latency printed at the end. If `check_contradiction_invalidates` cannot pass with the chosen model, go back to Task 0 step 3 and pick a stronger one.
- [ ] **Step 5: Commit** as `feat(memory): add agent-memory smoke test`.

### Task 3: Wire the clients and retire memory-search

**Files:**
- Modify: `claude/mcp.json`, `opencode/opencode.json`, `kilo/kilo.json`
- Modify: `tests/test_layout.sh` (replace `test_layout_memory_search_mcp_is_wired_everywhere`)
- Delete: `tools/bin/memory-search-mcp`
- Modify: `README.md` (the `tools/bin` row and the `memory-search` paragraph around lines 98-104; add the `agent-memory` server to the MCP list)

**Interfaces:**
- Consumes: the URL convention from Global Constraints.
- Produces: an `agent-memory` server in all three harnesses, named exactly `agent-memory`, so Task 4 and the tool names agents see (`mcp__agent-memory__add_memory`, and so on) agree.

- [ ] **Step 1: Write the failing test** `test_layout_agent_memory_mcp_is_wired_everywhere` in `tests/test_layout.sh`, with these assertions:
  - `jq -e '.mcpServers["agent-memory"] | .type == "http" and .url == "${AGENT_MEMORY_URL}"' claude/mcp.json`
  - `jq -e '.mcp.servers["agent-memory"] | .type == "remote" and .url == "{env:AGENT_MEMORY_URL}" and .disabled == false' opencode/opencode.json`
  - `jq -e '.mcp["agent-memory"] | .type == "remote" and .url == "{env:AGENT_MEMORY_URL}" and .enabled == true' kilo/kilo.json`
  - `test_layout_memory_search_is_gone`: none of the three configs has a `memory-search` key, and `tools/bin/memory-search-mcp` does not exist.
  - `test_layout_no_literal_memory_host`: none of the three configs contains `artonus.net`.
- [ ] **Step 2: Run** `bash tests/run.sh` and confirm the new tests fail.
- [ ] **Step 3: Edit the three configs** to add `agent-memory` and remove `memory-search`, matching each file's existing entry style. No auth header: access control is the tailnet.
- [ ] **Step 4: Delete** `tools/bin/memory-search-mcp` and rewrite the README paragraph to describe `agent-memory` in 3-4 lines (what it is, that it needs Tailscale and `AGENT_MEMORY_URL`, where the stack lives).
- [ ] **Step 5: Run** `bash tests/run.sh` until it passes, then `AI_SETUP_OVERLAY=<path> ./install.sh --dry-run`. The dry run may list `remove stale` only for the `memory-search-mcp` link and the `memory-search` server; anything else means the overlay path is wrong, so stop.
- [ ] **Step 6: Install** with `AI_SETUP_OVERLAY=<path> ./install.sh`, export `AGENT_MEMORY_URL`, and check `claude mcp list` and `opencode mcp list` show `agent-memory` connected.
- [ ] **Step 7: Commit** as `feat(memory): wire agent-memory MCP and drop memory-search`.

### Task 4: Rewrite the memory rules

**Files:**
- Modify: `shared/AGENTS.md` (replace the "Memory (Trilium)" section; leave "Notes (Trilium)" as is)
- Modify: `SECRETS.md` (add `AGENT_MEMORY_URL`; note it is a URL, not a secret, and needs Tailscale)
- Test: `tests/test_layout.sh`

**Interfaces:**
- Consumes: the `agent-memory` tool names and the group parameter name from Task 0.
- Produces: the written agent behaviour below, which the overlay can override for the default group.

- [ ] **Step 1: Write the failing test** `test_layout_agents_md_memory_section_uses_agent_memory`: `shared/AGENTS.md` contains `agent-memory`, `search_memory_facts` and `add_memory`, and does not contain `memory_search` or `#core`.
- [ ] **Step 2: Run** the test and confirm it fails.
- [ ] **Step 3: Write the section** (about 15 lines) with exactly these rules:
  - **Recall first:** at the start of a task, call `search_memory_facts` with a short description of the task, in the default group (`personal`; the work overlay sets `work`). Add `search_nodes` for a named service, person or ticket. Use what you find; do not ask for facts already stored.
  - **Store after** a decision, a state change ("X now owns Y"), a bug root cause with its fix, or a gotcha: one `add_memory` call per atomic, dated statement, written as a plain sentence naming its subject. No transcripts, no secrets, no temporary debugging output.
  - **Correct, don't pile up:** state the new fact as a new episode and the old one is invalidated by the server; to remove a wrong episode use `delete_episode` after asking the user.
  - **Unavailable:** if the `agent-memory` tools are missing or a call fails, carry on without memory and say so in one line; do not retry in a loop.
  - **Cost:** extraction runs an LLM per episode, so batch related facts into one episode and skip trivia.
- [ ] **Step 4: Run** `bash tests/run.sh`, then install with the overlay path as in Task 3 step 6.
- [ ] **Step 5: Commit** as `feat(memory): point agents at agent-memory instead of Trilium`.

### Task 5: Migrate existing memories and cut over

**Files:** none in the repo; this is a one-off run. Report the outcome to the user in chat.

- [ ] **Step 1: Export.** While the `trilium` MCP is reachable (it currently fails with an invalid URL, so fix `TRILIUM_MCP_URL` first, or read the notes in the Trilium web UI), list every note labelled `#memory` with its scope and project.
- [ ] **Step 2: Ask the user** to confirm which of them are still true and which group each belongs to. Skip stale ones. Project-scoped notes go into the group of their domain, with the repo name written into the sentence.
- [ ] **Step 3: Import.** Write each confirmed memory as an atomic episode with `add_memory` into the chosen group, then spot-check five of them with `search_memory_facts`.
- [ ] **Step 4: Cut over.** Leave the Trilium notes in place. Do not delete any memory notes without asking the user.

### Follow-ups (not part of this plan unless the user asks)

- A `SessionStart` hook for Claude Code that injects a reminder to recall, and a `PreCompact` hook that reminds the agent to store, only if the agents ignore the `AGENTS.md` rules in practice.
- Remove the `trilium` MCP, the `trilium-notes` skill, `meeting-notes` agent wiring and `TRILIUM_*` secrets, if the user decides to stop using Trilium for notes as well.
- Nightly backup of the FalkorDB volume with the method found in Task 0 step 1.

---

## Execution notes (2026-11-15)

Done: Tasks 0-4. Task 5 (migration) is waiting for the user.

Rulings made during execution:

- **Deploy location.** The stack lives in the homelab repo at `/opt/server/homelab/agent-memory/` (user's instruction, homelab conventions: `docker-compose.yaml`, data in `/opt/server/homelab-data/agent-memory/`, git-ignored `.env`), not in `deploy/agent-memory/` here. The repo-side deploy tests of Task 1 were dropped; verification is `docker compose config`, health checks and port probes.
- **Access control.** Uses the existing `chain-internal@file` (LAN `192.168.50.0/24` plus Tailscale `100.64.0.0/10`), so the host is also reachable from the LAN without Tailscale.
- **Endpoint.** `https://agent-memory.homelab.artonus.net/mcp` with **no trailing slash**. `/mcp/` answers 307 to an `http://` URL behind Traefik.
- **Providers.** OpenAI for both: `gpt-4.1-mini` (extraction) and `text-embedding-3-small`. The smoke test passes with it, including contradiction invalidation (about 8 s per episode).
- **FalkorDB password.** The official image ignores `FALKORDB_PASSWORD`; it is applied through `REDIS_ARGS=--requirepass ...`.
- **Smoke test.** Standard-library Python (`python3`, 3.9+) instead of a `uv` script: the MCP protocol is plain JSON-RPC over HTTP and the system Python is 3.9.
- **Commits.** None made, per the user's global rule (commit only when asked). The deletion of `tools/bin/memory-search-mcp` was staged by this work and ended up inside another session's commit `b0c6d0f` (agent-guard).
- **Final review.** Self-review only; no fresh reviewer was run.
