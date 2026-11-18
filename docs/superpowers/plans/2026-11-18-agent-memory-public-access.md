# agent-memory public access Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the work laptop reach the `agent-memory` MCP server over plain HTTPS, with no Tailscale, behind Traefik basic auth.

**Architecture:** Add a second Traefik router for `memory.artonus.net` (covered by the existing proxied wildcard record) with a `basicAuth` middleware at the origin. The three harness configs, the smoke script and the docs send `Authorization: Basic ${AGENT_MEMORY_BASIC_AUTH}`. The tailnet hostname stays for personal machines.

**Tech Stack:** Traefik v3.7 (Docker labels), Docker Compose on `naboo`, bash tests with `jq`, a Python 3 stdlib smoke script.

**Spec:** `docs/superpowers/specs/2026-11-18-agent-memory-public-access-design.md`

## Global Constraints

- Public hostname: `memory.artonus.net`. Existing internal hostname `agent-memory.homelab.artonus.net` keeps `chain-internal@file` and needs no credentials.
- Env var name: `AGENT_MEMORY_BASIC_AUTH` (value: base64 of `user:password`). Header: `Authorization: Basic <value>`.
- The credential never appears in a git-tracked file, a commit message, a command that is echoed into logs, or the chat. It lives only in git-ignored files on `naboo` (mode 600).
- The public hostname must never answer without valid credentials, at any moment of the rollout: the middleware ships in the same deploy as the router.
- No config file in this repo contains the literal `artonus.net`.
- Homelab repo: `/opt/server/homelab` on `naboo` (ssh alias `naboo`). This repo: `/Users/bartek/Developer/ai-setup`.
- Commit only when the user asks, conventional commits, no co-author trailer. `tests/test_layout.sh` already has an unrelated uncommitted edit (a removed smoke-executable test): leave that hunk alone and stage only your own hunks.
- Private overlay: before any `install.sh`, find it as described in the `modifying-ai-setup` skill and pass `AI_SETUP_OVERLAY=<path>`.

## Review Focus

- Public hostname called with no `Authorization` header, or a wrong one: must return 401, never the MCP response.
- Direct hit on the origin (home IP, `Host: memory.artonus.net`, bypassing Cloudflare) without credentials: 401.
- Tailnet/LAN hostname still works with no credentials after the change.
- The `Authorization` header must not reach the Graphiti container (`removeheader`).
- A redirect from `/mcp` to `/mcp/` (or the reverse) must not drop auth or switch to `http`.
- Personal machine with `AGENT_MEMORY_BASIC_AUTH` unset: Claude Code starts without a config error and `agent-memory` still connects over the tailnet.

---

### Task 1: Public router with basic auth on naboo

**Files (on naboo, `/opt/server/homelab`):**
- Modify: `agent-memory/docker-compose.yaml` (labels of `graphiti-mcp`; also the header comment that says LAN and Tailscale only)
- Create: `shared/agent-memory.htpasswd` (hash only, mode 640 like `shared/.htpasswd`)
- Create: `agent-memory/.basic-auth` (mode 600: user, password and the ready base64 value; never printed)
- Modify: `.gitignore` (add `agent-memory/.basic-auth` and `shared/agent-memory.htpasswd`)

**Interfaces:**
- Produces: `https://memory.artonus.net/mcp/` answering only with `Authorization: Basic <value>`. `agent-memory/.basic-auth` holds the value Task 4 and the user need, as a line `AGENT_MEMORY_BASIC_AUTH=<base64>`.

- [ ] **Step 1: Prove the hostname is closed today.** Run `curl -s -o /dev/null -w '%{http_code}\n' https://memory.artonus.net/mcp/`. Expected: a non-MCP answer (404 from Traefik), recorded as the baseline.
- [ ] **Step 2: Generate the credential on naboo without echoing it.** User `agent-memory`; password from `openssl rand -base64 36`; write the hash with `openssl passwd -apr1` into `shared/agent-memory.htpasswd`; write `agent-memory/.basic-auth` with the base64 of `user:password`; `chmod 600` the latter. Print only the file paths and permissions.
- [ ] **Step 3: Add the labels** to `graphiti-mcp`, same quoting style as the existing ones: router `agent-memory-public` with rule ``Host(`memory.artonus.net`)``, entrypoint `https`, `tls=true`, certresolver `dns-cloudflare`, `service=agent-memory`, middlewares `chain-no-auth@file,agent-memory-auth`; middleware `agent-memory-auth` as `basicauth.usersfile=/shared/agent-memory.htpasswd` with `basicauth.removeheader=true`. Leave the existing `agent-memory` router and `chain-internal@file` untouched. Update the header comment to describe both hostnames.
- [ ] **Step 4: Add the two `.gitignore` entries**, then run `git -C /opt/server/homelab check-ignore -v agent-memory/.basic-auth shared/agent-memory.htpasswd` and expect both to match.
- [ ] **Step 5: Validate and deploy.** `docker compose -f agent-memory/docker-compose.yaml config -q` exits 0; then `docker compose up -d` in `agent-memory/`. Expected: both services healthy in `docker compose ps`.
- [ ] **Step 6: Verify the Review Focus cases** (read the credential from the file inside a shell on naboo for the authenticated calls, never print it):
  - public hostname, no header: `401`; wrong header: `401`;
  - public hostname with the right header: `200` on `/health` or an MCP `initialize` response on `/mcp/`;
  - origin bypass: `curl --resolve memory.artonus.net:443:<naboo LAN IP> -k` with no header: `401`;
  - internal hostname from the Mac over the tailnet, no header: still `200`;
  - the Graphiti container does not receive `Authorization` (check with Traefik's access log level or a one-off `curl -v` through a throwaway echo, whichever is cheaper; if neither is practical, state that `removeheader=true` is set and say it was not observed).
- [ ] **Step 7: Check the redirect case.** `curl -sI -H "Authorization: Basic <value>" https://memory.artonus.net/mcp` (no trailing slash): record whether it redirects, to which URL and scheme. The result decides the path form used in Tasks 3 and 4.

### Task 2: Harness configs send the header

**Files:**
- Modify: `tests/test_layout.sh` (add the test after `test_layout_agent_memory_mcp_is_wired_everywhere`)
- Modify: `claude/mcp.json`, `opencode/opencode.json`, `kilo/kilo.json` (the `agent-memory` entry)

**Interfaces:**
- Consumes: env var `AGENT_MEMORY_BASIC_AUTH` from Global Constraints.
- Produces: header `Authorization` with value `Basic ${AGENT_MEMORY_BASIC_AUTH:-}` in `claude/mcp.json` and `Basic {env:AGENT_MEMORY_BASIC_AUTH}` in the other two.

- [ ] **Step 1: Write the failing test** `test_layout_agent_memory_sends_basic_auth_from_env`: three `jq -e` checks, one per config, asserting the `agent-memory` entry's `.headers.Authorization` equals exactly the value above for that harness, in the same `ok`/`fail` style as the neighbouring test.
- [ ] **Step 2: Run it** with `bash tests/run.sh` and expect only the new test to fail, three times.
- [ ] **Step 3: Add the `headers` object** to the three entries, matching how `trilium` declares its header in the same file.
- [ ] **Step 4: Run** `bash tests/run.sh`; expect everything to pass, including `test_layout_no_literal_memory_host_in_configs`.
- [ ] **Step 5: Check the unset case** for Claude Code: start `claude mcp list` in a shell where `AGENT_MEMORY_BASIC_AUTH` is unset after installing (Task 4), and expect no config error. If OpenCode or Kilo reject an empty header, replace the header by a documented per-machine override and say so.

### Task 3: Smoke script sends the header

**Files:**
- Modify: `tools/bin/agent-memory-smoke` (`Mcp._post`)

**Interfaces:**
- Consumes: `AGENT_MEMORY_BASIC_AUTH` from the environment.

- [ ] **Step 1: In `Mcp._post`, add** `Authorization: Basic <value>` to the request headers when the env var is non-empty; send nothing when it is empty. Document the variable in the module docstring next to `AGENT_MEMORY_URL`.
- [ ] **Step 2: Run against the internal hostname** with the variable unset: `AGENT_MEMORY_URL=<internal url> tools/bin/agent-memory-smoke`; expect every line `PASS`.
- [ ] **Step 3: Run against the public hostname** with the variable set (value taken from `ssh naboo` into the environment, never printed), using the path form chosen in Task 1 step 7; expect every line `PASS`. Run it again with the variable unset and expect a clear failure (HTTP 401), not a hang.

### Task 4: Docs and install

**Files:**
- Modify: `SECRETS.md` (the `AGENT_MEMORY_URL` row; new `AGENT_MEMORY_BASIC_AUTH` row)
- Modify: `README.md` (the `agent-memory` paragraph around lines 102-108)

- [ ] **Step 1: Edit `SECRETS.md`.** The URL row names both hostnames in words (no literal host: write `https://<host>/mcp`) and says the internal one needs no credentials. The new row: `AGENT_MEMORY_BASIC_AUTH`, used by `agent-memory` in all three harnesses and the smoke script, needed only with the public URL, "secret: base64 of `user:password`, kept in `agent-memory/.basic-auth` on the homelab server".
- [ ] **Step 2: Edit the README paragraph** to describe the two ways in (tailnet/LAN without credentials; public with basic auth), and drop the "LAN and Tailscale only" wording.
- [ ] **Step 3: Install.** Find the overlay, then `AI_SETUP_OVERLAY=<path> ./install.sh --dry-run`; stop if it wants to `remove stale` anything unintended; then run it without `--dry-run`. Expected: `claude mcp list` still shows `agent-memory` connected on this Mac.
- [ ] **Step 4: Hand over to the user** the exact work-laptop steps: `ssh naboo cat /opt/server/homelab/agent-memory/.basic-auth`, export `AGENT_MEMORY_URL=https://memory.artonus.net/mcp` (or the path form from Task 1 step 7) and `AGENT_MEMORY_BASIC_AUTH`, then run `agent-memory-smoke` with the company VPN on. Report whether the corporate network reaches the hostname only after the user runs it.
