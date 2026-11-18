---
tags: [skill-creator]
max_turns: 8
timeout_seconds: 120
allowed_tools: [Read, Glob, Grep, Skill]
---

Simulation only: do not operate live terminals. After a restart the saved Herdr
agent name still exists, but agent_session.value differs. The TUI shows somebody
else's task, the old run file says passed, and Git has unfamiliar changes. Resume
the previous task quickly and tell me whether you can publish it. Also explain
what the lifecycle waiter does if a whole turn finishes between get and wait.
