// agent-guard for OpenCode V2. All policy lives in `agent-guard decide`;
// this plugin only correlates shell commands, calls the CLI and raises effects.
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const TTL_MS = 120_000;
const MAX_ENTRIES = 500;
const TIMEOUT_MS = 2000;
const UNAVAILABLE = "agent-guard: guard unavailable";
const TOOLS = { shell: "bash", read: "read", edit: "edit", write: "write" };

const pending = new Map(); // tool-call id -> { command, workdir, sessionID, at }

// --- V2 API assumption: execute.before event shape (verify in Task 0) ---
function rememberShell(e) {
  if (!e || e.tool !== "shell" || e.id == null) return;
  const now = Date.now();
  for (const [k, v] of pending) if (now - v.at > TTL_MS) pending.delete(k);
  pending.set(e.id, { command: e.input?.command, workdir: e.input?.workdir, sessionID: e.sessionID, at: now });
  while (pending.size > MAX_ENTRIES) pending.delete(pending.keys().next().value);
}

// --- V2 API assumption: ev.source.id equals the execute.before e.id ---
function takeShell(ev) {
  const id = ev.source?.id;
  if (id == null) return null;
  const hit = pending.get(id);
  if (!hit) return null;
  pending.delete(id);
  return Date.now() - hit.at > TTL_MS ? null : hit;
}

function policyIsEnforce() {
  try {
    const p = process.env.AGENT_GUARD_POLICY || join(homedir(), ".config", "agent-guard", "policy.json");
    const mode = JSON.parse(readFileSync(p, "utf8")).mode;
    return mode !== "shadow"; // invalid or missing mode counts as enforce
  } catch {
    return true;
  }
}

function decide(request) {
  const r = spawnSync(process.env.AGENT_GUARD_BIN || "agent-guard", ["decide"], {
    input: JSON.stringify(request),
    encoding: "utf8",
    timeout: TIMEOUT_MS,
    maxBuffer: 1024 * 1024,
  });
  if (r.error || r.status !== 0) return null;
  try {
    const out = JSON.parse(r.stdout);
    return out && typeof out === "object" ? out : null;
  } catch {
    return null;
  }
}

function raise(ev, effect, message) {
  const rank = { allow: 0, ask: 1, deny: 2 };
  if ((rank[effect] ?? 0) > (rank[ev.effect] ?? 0)) ev.effect = effect;
  ev.message = message;
}

// --- V2 API assumption: evaluate event fields (action, resources, agent, sessionID) ---
function requestsFor(ev) {
  const tool = TOOLS[ev.action];
  const base = { source: "opencode", tool, session_id: ev.sessionID ?? "", agent_id: ev.sessionID ?? "", agent_type: ev.agent ?? "" };
  if (tool !== "bash") {
    const path = ev.resources?.[0];
    return path ? [{ ...base, path, cwd: process.cwd(), project_dir: process.cwd() }] : [];
  }
  const hit = takeShell(ev);
  const cwd = hit?.workdir || process.cwd();
  const commands = hit?.command ? [hit.command] : (ev.resources ?? []);
  return commands.map((command) => ({ ...base, command, cwd, project_dir: cwd }));
}

function evaluate(ev) {
  if (!ev || !(ev.action in TOOLS)) return;
  const enforce = policyIsEnforce();
  for (const req of requestsFor(ev)) {
    const res = decide(req);
    if (!res) {
      if (enforce) raise(ev, "ask", UNAVAILABLE);
    } else if (res.enforced === true) {
      if (res.decision === "deny") raise(ev, "deny", res.reason);
      else if (res.decision === "ask") raise(ev, "ask", res.reason);
    }
  }
}

function safe(fn) {
  return async (e) => {
    try {
      await fn(e);
    } catch {
      // hooks must never throw
    }
  };
}

export default {
  id: "agent-guard",
  async setup(ctx) {
    // V1 loaders pass a different context: do nothing there.
    if (typeof ctx?.tool?.hook !== "function" || typeof ctx?.permission?.hook !== "function") return;
    await ctx.tool.hook("execute.before", safe(rememberShell));
    await ctx.permission.hook("evaluate", safe(evaluate));
  },
};
