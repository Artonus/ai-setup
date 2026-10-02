# Secrets checklist

Names only. Never put a value in this repo. Export these in your shell profile
(`~/.zshrc`, `~/.zprofile` or `~/.bashrc`) or load them from a password manager before
starting the tool. OpenCode reads `{env:VAR}` references at startup; a missing variable
disables or breaks only the server that uses it.

Work-only variables live in the private overlay's own `SECRETS.md`.

## OpenCode

| Variable | Used by | Needed? | How to get it |
|---|---|---|---|
| `CONTEXT7_API_KEY` | `context7` MCP | Recommended (higher rate limits) | Create a key in your Context7 account dashboard |
| `GOOGLE_MCP_CLIENT_ID` | `google-calendar` MCP | Only to enable it | Google Cloud OAuth client (web application) |
| `GOOGLE_MCP_CLIENT_SECRET` | `google-calendar` MCP | Only to enable it | Same OAuth client |
| `ANTHROPIC_API_KEY` | Anthropic models in OpenCode | Only if you use Claude there | Claude Console. Subscriptions cannot be used. Alternatively run `opencode auth login` |

Google Calendar setup (it ships disabled): enable the Calendar API and Calendar MCP API in a
Cloud project, create a web OAuth client, export the two variables, set `"enabled": true` in
your overlay, then run `opencode mcp auth google-calendar`.

## Browser sign-ins (no variable)

| Service | Command or action |
|---|---|
| Todoist MCP (OpenCode) | Opens the browser on first use, or `opencode mcp auth todoist` |

## Claude Code

Nothing to export for the base setup. The `context7` plugin and the claude.ai connectors
(Todoist, Google Calendar) authenticate inside Claude Code (`/mcp`) or in claude.ai settings.

## Check it

```bash
opencode mcp list     # shows each server and whether it connected or needs auth
env | grep -c -E '^(CONTEXT7_API_KEY|ANTHROPIC_API_KEY)='   # counts set variables, prints no values
```
