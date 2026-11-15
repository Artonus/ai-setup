// Tests for the OpenCode V2 agent-guard plugin (node --test).
import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, readFileSync, chmodSync, mkdirSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import plugin from "../opencode/plugins/agent-guard/index.js";

const dir = mkdtempSync(join(tmpdir(), "ag-oc-"));
const stub = join(dir, "stub.sh");
const stdinFile = join(dir, "stdin.log");
writeFileSync(
  stub,
  `#!/bin/sh
cat >> "$STUB_IN"; echo >> "$STUB_IN"
[ -n "$STUB_SLEEP" ] && sleep "$STUB_SLEEP"
[ -n "$STUB_OUT" ] && printf '%s' "$STUB_OUT"
exit "\${STUB_EXIT:-0}"
`,
);
chmodSync(stub, 0o755);
process.env.AGENT_GUARD_BIN = stub;
process.env.STUB_IN = stdinFile;
const logFile = join(dir, "decisions.jsonl");
process.env.AGENT_GUARD_LOG = logFile; // never write the real decision log

function policy(mode) {
  const p = join(dir, `policy-${mode}.json`);
  writeFileSync(p, JSON.stringify({ mode }));
  process.env.AGENT_GUARD_POLICY = p;
}
function stubOut(decision, enforced = true, reason = "because") {
  process.env.STUB_OUT = JSON.stringify({ decision, rule: "r", reason, mode: enforced ? "enforce" : "shadow", enforced });
  delete process.env.STUB_EXIT;
  delete process.env.STUB_SLEEP;
}
async function load() {
  const hooks = {};
  const ctx = {
    tool: { hook: async (n, f) => { hooks[n] = f; } },
    permission: { hook: async (n, f) => { hooks[n] = f; } },
  };
  await plugin.setup(ctx);
  return hooks;
}
const requests = () =>
  readFileSync(stdinFile, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
const lastRequest = () => requests().at(-1);
const shellEvt = (id, command, workdir) => ({ tool: "shell", id, sessionID: "s1", input: { command, workdir } });
const permEvt = (o) => ({ sessionID: "s1", effect: "allow", resources: [], ...o });

test("setup is a no-op without ctx.tool and ctx.permission", async () => {
  assert.equal(plugin.id, "agent-guard");
  await plugin.setup({});
  await plugin.setup({ tool: { hook: () => {} } });
  await plugin.setup({ tool: {}, permission: {} });
});

test("shell ask when enforced", async () => {
  policy("enforce"); stubOut("ask", true, "needs a look");
  const h = await load();
  await h["execute.before"](shellEvt("c1", "kubectl delete ns demo", "/w"));
  const ev = permEvt({ action: "shell", resources: ["other"], source: { type: "tool", id: "c1" }, agent: "build" });
  await h.evaluate(ev);
  assert.equal(ev.effect, "ask");
  assert.equal(ev.message, "needs a look");
  const r = lastRequest();
  assert.equal(r.source, "opencode");
  assert.equal(r.tool, "bash");
  assert.equal(r.command, "kubectl delete ns demo");
  assert.equal(r.cwd, "/w");
  assert.equal(r.agent_type, "build");
  assert.equal(r.agent_id, "s1");
});

test("deny wins and an incoming deny is never lowered", async () => {
  policy("enforce");
  const h = await load();
  stubOut("deny", true, "no way");
  const a = permEvt({ action: "shell", resources: ["x"], effect: "ask" });
  await h.evaluate(a);
  assert.equal(a.effect, "deny");
  assert.equal(a.message, "no way");
  stubOut("ask", true, "hm");
  const b = permEvt({ action: "shell", resources: ["x"], effect: "deny" });
  await h.evaluate(b);
  assert.equal(b.effect, "deny");
  stubOut("none", true, "");
  const c = permEvt({ action: "shell", resources: ["x"], effect: "ask" });
  await h.evaluate(c);
  assert.equal(c.effect, "ask");
  assert.equal(c.message, undefined);
});

test("not enforced leaves the event untouched", async () => {
  policy("shadow"); stubOut("deny", false, "shadow only");
  const h = await load();
  const ev = permEvt({ action: "shell", resources: ["rm -rf /"] });
  await h.evaluate(ev);
  assert.equal(ev.effect, "allow");
  assert.equal(ev.message, undefined);
});

test("uncorrelated shell falls back to resources", async () => {
  policy("enforce"); stubOut("none", true, "");
  const h = await load();
  await h.evaluate(permEvt({ action: "shell", resources: ["ls", "pwd"], source: { type: "tool", id: "nope" } }));
  const rs = requests().slice(-2);
  assert.deepEqual(rs.map((r) => r.command), ["ls", "pwd"]);
});

test("edit and write pass the path to decide", async () => {
  policy("enforce"); stubOut("none", true, "");
  const h = await load();
  for (const t of ["edit", "write"]) {
    await h.evaluate(permEvt({ action: t, resources: ["/etc/hosts"] }));
    const r = lastRequest();
    assert.equal(r.tool, t);
    assert.equal(r.path, "/etc/hosts");
  }
  await h.evaluate(permEvt({ action: "read", resources: ["/a/b"] }));
  assert.equal(lastRequest().tool, "read");
  assert.equal(lastRequest().path, "/a/b");
});

test("subprocess failure asks in enforce and is silent in shadow", async () => {
  const h = await load();
  for (const mode of ["enforce", "shadow"]) {
    policy(mode);
    for (const kind of ["exit", "hang", "garbage"]) {
      delete process.env.STUB_SLEEP; delete process.env.STUB_EXIT;
      process.env.STUB_OUT = "";
      if (kind === "exit") process.env.STUB_EXIT = "1";
      if (kind === "hang") process.env.STUB_SLEEP = "5";
      if (kind === "garbage") process.env.STUB_OUT = "not json";
      const ev = permEvt({ action: "shell", resources: ["ls"] });
      await h.evaluate(ev);
      if (mode === "enforce") {
        assert.equal(ev.effect, "ask", `${mode}/${kind}`);
        assert.equal(ev.message, "agent-guard: guard unavailable");
      } else {
        assert.equal(ev.effect, "allow", `${mode}/${kind}`);
        assert.equal(ev.message, undefined);
      }
    }
  }
  // missing policy counts as enforce
  process.env.AGENT_GUARD_POLICY = join(dir, "missing.json");
  process.env.STUB_EXIT = "1";
  const ev = permEvt({ action: "shell", resources: ["ls"] });
  await h.evaluate(ev);
  assert.equal(ev.effect, "ask");
});

test("unrelated actions are ignored", async () => {
  policy("enforce"); stubOut("deny", true, "x");
  const h = await load();
  const ev = permEvt({ action: "webfetch", resources: ["https://x"] });
  await h.evaluate(ev);
  assert.equal(ev.effect, "allow");
});

test("correlation entries expire after 120 s and are capped at 500", async () => {
  policy("enforce"); stubOut("none", true, "");
  const h = await load();
  const realNow = Date.now;
  let now = realNow();
  Date.now = () => now;
  try {
    await h["execute.before"](shellEvt("old", "stored-old"));
    now += 121_000;
    await h.evaluate(permEvt({ action: "shell", resources: ["fallback"], source: { type: "tool", id: "old" } }));
    assert.equal(lastRequest().command, "fallback");

    for (let i = 0; i < 501; i++) await h["execute.before"](shellEvt(`k${i}`, `cmd${i}`));
    await h.evaluate(permEvt({ action: "shell", resources: ["fb"], source: { type: "tool", id: "k0" } }));
    assert.equal(lastRequest().command, "fb");
    await h.evaluate(permEvt({ action: "shell", resources: ["fb"], source: { type: "tool", id: "k500" } }));
    assert.equal(lastRequest().command, "cmd500");
  } finally {
    Date.now = realNow;
  }
});

test("hooks never throw on malformed events", async () => {
  const h = await load();
  await h["execute.before"](null);
  await h["execute.before"]({ tool: "shell", id: "z" });
  await h.evaluate(null);
  await h.evaluate({ action: "shell" });
});

test("adapter exception asks in enforce and is silent in shadow", async () => {
  const h = await load();
  stubOut("none", true, "");
  for (const mode of ["enforce", "shadow"]) {
    policy(mode);
    const ev = permEvt({ action: "shell", resources: "x" });
    await h.evaluate(ev);
    assert.equal(ev.effect, mode === "enforce" ? "ask" : "allow", mode);
    assert.equal(ev.message, mode === "enforce" ? "agent-guard: guard unavailable" : undefined);
  }
});

test("unrecognised decide replies count as guard unavailable", async () => {
  const h = await load();
  for (const out of ["{}", "[]", '{"decision":"maybe","enforced":true}', '{"decision":"ask"}']) {
    for (const mode of ["enforce", "shadow"]) {
      policy(mode);
      process.env.STUB_OUT = out;
      const ev = permEvt({ action: "shell", resources: ["ls"] });
      await h.evaluate(ev);
      assert.equal(ev.effect, mode === "enforce" ? "ask" : "allow", `${out} ${mode}`);
      assert.equal(ev.message, mode === "enforce" ? "agent-guard: guard unavailable" : undefined);
    }
  }
});

test("no buildable request counts as guard unavailable", async () => {
  const h = await load();
  stubOut("none", true, "");
  const cases = [{ action: "shell", resources: [] }, { action: "shell" }, { action: "read", resources: [] }, { action: "edit" }, { action: "write", resources: [] }];
  for (const mode of ["enforce", "shadow"]) {
    policy(mode);
    for (const c of cases) {
      const ev = permEvt(c);
      await h.evaluate(ev);
      assert.equal(ev.effect, mode === "enforce" ? "ask" : "allow", `${c.action} ${mode}`);
      assert.equal(ev.message, mode === "enforce" ? "agent-guard: guard unavailable" : undefined);
    }
  }
});

test("reason is coerced, capped and defaulted", async () => {
  policy("enforce");
  const h = await load();
  process.env.STUB_OUT = JSON.stringify({ decision: "ask", enforced: true, reason: "x".repeat(900) });
  let ev = permEvt({ action: "shell", resources: ["ls"] });
  await h.evaluate(ev);
  assert.equal(ev.message.length, 500);
  process.env.STUB_OUT = JSON.stringify({ decision: "deny", enforced: true });
  ev = permEvt({ action: "shell", resources: ["ls"] });
  await h.evaluate(ev);
  assert.equal(ev.message, "agent-guard");
  process.env.STUB_OUT = JSON.stringify({ decision: "deny", enforced: true, reason: 42 });
  ev = permEvt({ action: "shell", resources: ["ls"] });
  await h.evaluate(ev);
  assert.equal(ev.message, "42");
});

test("every resource of a read, edit or write is checked, strictest wins", async () => {
  policy("enforce");
  const h = await load();
  process.env.STUB_OUT = "";
  // the stub answers per request: use a shell stub that denies only ~/.zshrc
  const picky = join(dir, "picky.sh");
  writeFileSync(
    picky,
    `#!/bin/sh
in=$(cat); echo "$in" >> "$STUB_IN"
case "$in" in
  *zshrc*) printf '%s' '{"decision":"deny","rule":"r","reason":"protected","mode":"enforce","enforced":true}' ;;
  *) printf '%s' '{"decision":"none","rule":"","reason":"","mode":"enforce","enforced":true}' ;;
esac
`,
  );
  chmodSync(picky, 0o755);
  const saved = process.env.AGENT_GUARD_BIN;
  process.env.AGENT_GUARD_BIN = picky;
  try {
    const ev = permEvt({ action: "edit", resources: ["/proj/a.txt", "~/.zshrc"] });
    await h.evaluate(ev);
    assert.equal(ev.effect, "deny");
    assert.equal(ev.message, "protected");
    assert.deepEqual(requests().slice(-2).map((r) => r.path), ["/proj/a.txt", "~/.zshrc"]);
  } finally {
    process.env.AGENT_GUARD_BIN = saved;
  }
});

test("a weaker answer does not overwrite the message of a raised effect", async () => {
  policy("enforce"); stubOut("ask", true, "second");
  const h = await load();
  const ev = permEvt({ action: "shell", resources: ["a", "b"], effect: "ask" });
  ev.message = "first";
  await h.evaluate(ev);
  assert.equal(ev.effect, "ask");
  assert.equal(ev.message, "first");
});

test("inherited object keys are not tools", async () => {
  policy("enforce"); stubOut("deny", true, "x");
  const h = await load();
  for (const action of ["constructor", "toString", "__proto__"]) {
    const ev = permEvt({ action, resources: ["x"] });
    await h.evaluate(ev);
    assert.equal(ev.effect, "allow", action);
  }
});

test("the binary defaults to ~/bin/agent-guard and the policy honours XDG_CONFIG_HOME", async () => {
  const home = join(dir, "fakehome");
  mkdirSync(join(home, "bin"), { recursive: true });
  const bin = join(home, "bin", "agent-guard");
  writeFileSync(bin, `#!/bin/sh\ncat >> "$STUB_IN"; echo >> "$STUB_IN"\nprintf '%s' '{"decision":"ask","rule":"r","reason":"from home bin","mode":"enforce","enforced":true}'\n`);
  chmodSync(bin, 0o755);
  const xdg = join(dir, "xdg");
  mkdirSync(join(xdg, "agent-guard"), { recursive: true });
  writeFileSync(join(xdg, "agent-guard", "policy.json"), JSON.stringify({ mode: "enforce" }));
  const saved = { b: process.env.AGENT_GUARD_BIN, p: process.env.AGENT_GUARD_POLICY, h: process.env.HOME, x: process.env.XDG_CONFIG_HOME };
  delete process.env.AGENT_GUARD_BIN; delete process.env.AGENT_GUARD_POLICY;
  process.env.HOME = home; process.env.XDG_CONFIG_HOME = xdg;
  try {
    const h = await load();
    const ev = permEvt({ action: "shell", resources: ["ls"] });
    await h.evaluate(ev);
    assert.equal(ev.effect, "ask");
    assert.equal(ev.message, "from home bin");
  } finally {
    for (const [k, v] of [["AGENT_GUARD_BIN", saved.b], ["AGENT_GUARD_POLICY", saved.p], ["HOME", saved.h], ["XDG_CONFIG_HOME", saved.x]]) {
      if (v === undefined) delete process.env[k]; else process.env[k] = v;
    }
  }
});

test("setup writes one plugin-loaded log line and never throws", async () => {
  policy("shadow");
  const before = existsSync(logFile) ? readFileSync(logFile, "utf8").split("\n").filter(Boolean).length : 0;
  await load();
  const lines = readFileSync(logFile, "utf8").split("\n").filter(Boolean);
  assert.equal(lines.length, before + 1);
  const e = JSON.parse(lines.at(-1));
  assert.equal(e.source, "opencode");
  assert.equal(e.tool, "setup");
  assert.equal(e.decision, "none");
  assert.equal(e.rule, "plugin-loaded");
  assert.equal(e.mode, "shadow");
  // an unwritable log path must not break setup
  const saved = process.env.AGENT_GUARD_LOG;
  process.env.AGENT_GUARD_LOG = join(dir, "decisions.jsonl", "nope");
  try { await load(); } finally { process.env.AGENT_GUARD_LOG = saved; }
});
