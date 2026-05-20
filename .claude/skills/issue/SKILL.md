---
name: issue
description: GitHub issue-driven workflow for this repo. Use it to (a) file a new issue as bug/feature/enhancement/question, (b) break an agreed implementation plan into a list of issues, (c) start work on an existing issue by creating a branch from dev, or (d) open a PR back to dev when the work is ready. Invoke proactively when you encounter work that is out-of-scope for the current task and should be tracked, or when the user agrees to a multi-step implementation plan. Also user-invocable as /issue.
---

# Issue-driven workflow

All work on this repo flows through GitHub issues. Pick the flow below that matches the situation.

## Prerequisites — check once per session

1. **`gh` CLI installed and authenticated.** Run `gh --version`. If missing, offer to install:
   - Windows: `winget install --id GitHub.cli --source winget`
   - Then `gh auth login` (user must complete in browser).
   Do not proceed until `gh auth status` succeeds.
2. **`dev` branch exists on origin.** Run `git rev-parse --verify origin/dev`. If it fails, stop and tell the user to create it manually:
   ```
   git checkout master && git pull && git checkout -b dev && git push -u origin dev
   ```
   Do **not** auto-create the `dev` branch.
3. **Labels exist.** First time only, run `gh label list`. If any of `bug`, `feature`, `enhancement`, `question` are missing, create them:
   ```
   gh label create bug         --color d73a4a --description "Something is broken"
   gh label create feature     --color a2eeef --description "New capability"
   gh label create enhancement --color 84b6eb --description "Improvement to existing functionality"
   gh label create question    --color d876e3 --description "Open question needing an answer"
   ```

## Flow A — File a single issue

Use when the user asks to file an issue, OR when you (Claude) encounter work that is out-of-scope for the current task and should be tracked.

1. **Pick the type:**
   - `bug` — existing behavior is broken or incorrect
   - `feature` — a capability that doesn't exist yet
   - `enhancement` — improvement to something that already exists
   - `question` — open question that must be answered before work can proceed
2. **Draft the body** using the matching template at [.github/ISSUE_TEMPLATE/{type}.md](../../../.github/ISSUE_TEMPLATE/). Fill in every section — leave sections blank only if genuinely not applicable, and note why.
3. **Confirm with the user** — show the title, the chosen label, and the body. Wait for approval before creating.
4. **Create the issue.** Write the body to a temp file and use `--body-file` so multiline content survives the shell:
   ```
   gh issue create --title "<title>" --body-file <tmp.md> --label "<type>"
   ```
5. **Report the URL** back to the user.

**Out-of-scope discoveries during other work:** do not stop to file the issue. Note it, finish what you were doing, then ask the user at the end whether to file (one issue or several).

## Flow B — Plan → list of issues

Use when the user agrees to an implementation plan (typically after ExitPlanMode, or after an explicit "let's do that").

1. Break the plan into **discrete, independently-shippable units**. Each unit becomes one issue. Avoid an issue per file or per function — group by deliverable.
2. Assign a type to each unit (usually `feature` or `enhancement`).
3. Present the full list to the user as a numbered draft: each entry is `title` + type + one-line summary. Ask for approval or edits **before** creating any issues.
4. After approval, create them in order. If there is a natural parent/meta issue, create it first and reference the children in its body (`- [ ] #<num>`). Cross-link dependencies in child bodies (`Blocked by #N`).
5. Report the URLs as a list.

## Flow C — Start working on an issue

Use when the user says something like "start working on issue #42", "let's tackle 42", or "pick up #42".

1. Fetch the issue to get the title and confirm it exists:
   ```
   gh issue view <N> --json number,title,labels,state
   ```
   If state is `CLOSED`, stop and confirm with the user.
2. Generate the branch name: `issue-<num>-<slug>` where `<slug>` is the title kebab-cased, articles and filler words dropped, max ~50 chars.
   - Example: issue #42 "Port the WISA connector to Dart" → `issue-42-port-wisa-connector-to-dart`
3. Branch from the latest `dev`:
   ```
   git checkout dev
   git pull origin dev
   git checkout -b issue-<num>-<slug>
   ```
4. Tell the user the branch name and confirm it's ready for work.

## Flow D — Open a PR

Use when the user says the work is ready, or asks to open a PR.

1. Confirm the working tree is clean: `git status`. If there are uncommitted changes, ask whether to commit them first — do not proceed with a dirty tree.
2. Push the branch if not already pushed: `git push -u origin <branch>`.
3. Open the PR **against `dev`** (never against `master`). Use a HEREDOC so the body formats correctly:
   ```
   gh pr create --base dev --title "<title>" --body "$(cat <<'EOF'
   ## Summary
   - <bullet>
   - <bullet>

   ## Test plan
   - [ ] <how to verify>

   Closes #<issue-number>
   EOF
   )"
   ```
4. Report the PR URL.

## Hard rules

- **Never** target `master` from this skill — PRs always go to `dev`.
- **Never** push directly to `master` or `dev`.
- **Never** auto-create the `dev` branch; the user owns that decision.
- If the user is mid-task and a new concern surfaces, ask "file as issue, or fold into current work?" — don't silently expand scope.
