---
description: Commit the staged changes with a conventional commit message
---

Commit the currently staged changes.

1. Run `git diff --staged` to see exactly what will be committed. If nothing is staged, say so and stop. Do not stage anything yourself.
2. Run `git log --oneline -10` to check the repo's commit style.
3. Write the message in conventional commit format (`type(scope): subject`, imperative mood, subject under 72 characters), unless the recent history clearly uses another style; then follow that style. Add a short body only when the why is not obvious from the diff.
4. Commit with `git commit`. Do not push.
