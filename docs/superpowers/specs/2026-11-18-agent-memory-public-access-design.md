# agent-memory on a public hostname with Traefik basic auth (design)

Date: 2026-11-18. Size: small change in this repo, plus a change in the homelab repo on `naboo`.

Revision note: the first version of this design used a Cloudflare Tunnel plus a Cloudflare Access
service token. Recon on `naboo` showed the homelab already publishes services through the Cloudflare
proxy with a wildcard `*.artonus.net` record and an open port 443 (for example `notes.artonus.net/mcp`,
guarded by its own token). The tunnel and Zero Trust are not needed, and an edge-only check would leave
the open origin unprotected. This version reuses the existing pattern and checks credentials in Traefik.

## Intent and why

The company VPN makes the Tailscale route to `agent-memory` time out, and running Tailscale on the
work laptop makes the whole internet connection unstable there. The work laptop needs a way to
reach the memory server without Tailscale or any VPN client.

## Goals

- The work laptop reaches `agent-memory` over plain HTTPS through the company network and VPN.
- Only requests with valid credentials reach the server, including requests that bypass Cloudflare
  and hit the home IP directly.
- Personal machines keep working unchanged on the tailnet hostname, with no credentials.

## Non-goals and anti-goals

- No change to Graphiti, FalkorDB or the memory data model.
- No Cloudflare Tunnel, no Cloudflare Zero Trust or Access.
- Anti-goal: the server must never be reachable without authentication on the public hostname,
  even briefly during rollout (it has no auth of its own).
- Anti-goal: the credential never lands in a git-tracked file or a commit message.

## Constraints

- Traefik v3 on `naboo` reads Docker labels and `/rules`; `/opt/server/homelab/shared` is mounted
  at `/shared` in the Traefik container; `agent-memory/.env` is already git-ignored.
- A wildcard proxied record for `*.artonus.net` already exists, so a new hostname needs no DNS change.
- All three harnesses already send env-var headers (`trilium`, `context7`).
- Secrets never go into files in git or into commit messages.

## Approaches considered

- Cloudflare Tunnel plus Cloudflare Access service token (the first design): adds a new component
  and a Cloudflare account setup, and the open origin on 443 would still need its own check.
- Tailscale Funnel: the `ts.net` hostname may be filtered at the company.
- **Chosen: public hostname through the existing Cloudflare proxy, with Traefik `basicAuth` at the
  origin.** One Traefik-native credential check, one header on the client, no new components.
  Trade-off: a single shared credential, so it must be long and random; Cloudflare can see the traffic.

## Design

1. **Homelab repo.** A second Traefik router `agent-memory-public` for `Host(memory.artonus.net)` on the
   same service, with middlewares `chain-no-auth@file` and a new `basicAuth` middleware
   `agent-memory-auth` that reads `/shared/agent-memory.htpasswd` and removes the `Authorization`
   header before forwarding. The existing `homelab.artonus.net` router with `chain-internal` stays.
   The credential is a long random password; the htpasswd hash and the ready-to-use client value
   live only on `naboo`, in git-ignored files.
2. **This repo, harness configs.** The `agent-memory` entry in `claude/mcp.json`, `opencode/opencode.json`
   and `kilo/kilo.json` sends `Authorization: Basic <value>` from the env var `AGENT_MEMORY_BASIC_AUTH`
   (base64 of `user:password`). Unset on personal machines, where the header is harmless.
3. **This repo, docs.** `SECRETS.md` lists `AGENT_MEMORY_BASIC_AUTH` as optional and secret, and the URL
   row and README paragraph describe both hostnames.
4. **Tests.** `tests/test_layout.sh` checks the header in all three configs references only the env var.
5. **Smoke test.** `tools/bin/agent-memory-smoke` sends the same header from the same env var.
6. **Work laptop.** Export `AGENT_MEMORY_URL` (public hostname) and `AGENT_MEMORY_BASIC_AUTH`, run
   `agent-memory-smoke` with the company VPN on.

## Left to the builder

- Claude Code fails on an undefined `${VAR}` without a default, so use `${VAR:-}` there; check how
  OpenCode and Kilo handle an unset `{env:VAR}`.
- Confirm the `/mcp` path works end to end through Cloudflare without a redirect that drops auth or
  switches to `http`; the smoke script uses `/mcp/`, the docs say `/mcp`. Make the docs match what works.
- Confirm Cloudflare does not break the streamable HTTP responses.

## Decisions to confirm by running it

- Whether the company VPN lets traffic through to `memory.artonus.net` (step 6, on the work laptop).
