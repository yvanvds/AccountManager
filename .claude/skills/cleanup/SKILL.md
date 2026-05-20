---
name: cleanup
description: Post-merge branch tidying for this repo. Run after a PR merges to refresh local `dev`, drop stale remote-tracking refs, delete local branches that have been merged or whose upstream is gone, and close the GitHub issues those branches were tracking. Pairs with the `/issue` skill — `/issue` creates branches, this skill reaps them. Never touches `dev` or `master`, never force-deletes unmerged work. User-invocable as /cleanup.
---

# Post-merge cleanup

Use this after a successful PR merge to keep the local working copy aligned with `dev`, prune stale branches, and close the GitHub issues those branches were tracking. Pairs with the `/issue` skill.

## When to use

- The user invokes `/cleanup`.
- A PR was just merged and the user confirms it's safe to tidy up.

Do **not** run this proactively during other work. It's a deliberate end-of-iteration step.

## Hard rules

- **Never** delete `dev` or `master`. Even if `git branch --merged` lists them, skip.
- **Never** use `git branch -D` (force-delete). Only `git branch -d` (safe — refuses if a branch isn't fully merged).
- **Never** `git push --delete`. Remote-branch deletion is the PR merge setting's job, not this skill's.
- **Never** run on a dirty working tree without explicit user consent — uncommitted work could be lost.
- **Confirm before deleting or closing.** Print the planned actions (branch deletes + issue closes) in one list and wait for the user's "yes" (or list of exceptions) before anything runs.
- **Only close issues whose branch you successfully delete.** If `git branch -d` refused (unmerged work), leave the issue open — the user may still be working on it.

## Flow

### Step 1 — Verify clean working tree

```
git status --porcelain
```

If the output is non-empty, stop and report the uncommitted changes. Do not proceed unless the user explicitly says "discard and continue" — and even then, only after confirming nothing important is being lost.

### Step 2 — Switch to `dev` and pull with prune

```
git checkout dev
git pull --prune origin dev
```

`--prune` drops local remote-tracking refs whose remote branch has been deleted (typically after a PR merge with "delete branch" enabled on GitHub).

### Step 3 — Identify candidate branches

Two categories qualify for safe deletion:

```
# (a) Fully merged into dev:
git branch --merged dev

# (b) Upstream is gone (PR merged + remote branch deleted):
git branch -vv | grep ': gone\]'
```

Combine the two lists, deduplicate, and explicitly drop `dev` and `master` from the result. Drop the current branch indicator (`*`) too.

### Step 4 — Look up the issue each branch tracks

For every candidate branch matching `issue-<num>-*`, extract `<num>` and query the issue's current state:

```
gh issue view <num> --json number,state,title
```

Classify the result:

- **State `OPEN`** → eligible to close after we delete the branch.
- **State `CLOSED`** → nothing to do (typically the PR closed it via `Closes #N`).
- **No matching issue / `gh` errors** → skip the issue side, but still process the branch.

Branches that don't match `issue-<num>-*` (ad-hoc/experiment branches) are processed for deletion only; there's no issue to close.

### Step 5 — Confirm with the user

Print one combined plan as a numbered review. For each branch show why it qualifies and what will happen to the linked issue:

```
1. issue-23-set-up-ci-with-sonarcloud  (merged into dev) — closes issue #23 "Set up CI with SonarCloud"
2. issue-19-build-account-core         (upstream gone)   — issue #19 already CLOSED, leave it
3. experiment-azure-delta-spike        (merged into dev) — no linked issue
```

Then ask:

> "Delete these N branches and close the listed open issues? (yes / no / skip `<numbers>`)"

- "no" → stop, report nothing deleted/closed.
- skip `<numbers>` → drop those entries, continue with the rest.
- "yes" / confirm → proceed.

### Step 6 — Delete branches

For each approved branch:

```
git branch -d <branch>
```

If `git branch -d` refuses (branch is not fully merged), do **not** retry with `-D` and do **not** close the linked issue. Skip and report:

> "Branch `<X>` has unmerged work — skipped (issue #<N> left open). Use `git branch -D <X>` manually if you're sure."

### Step 7 — Close issues whose branch deletion succeeded

For each branch that was actually deleted in Step 6 AND has a linked issue still in state `OPEN`:

```
gh issue close <num> --comment "Branch <branch> deleted via /cleanup after merge."
```

If `gh issue close` fails (network, auth, permission), report the failure and leave the issue alone — the branch deletion still stands.

### Step 8 — Report

Print a short summary:

- N branches deleted (list them).
- M branches skipped (list them with reasons).
- K issues closed (list `#<num>`s, with the merged-PR context if available).
- L issues left open (list `#<num>`s — typically because the branch was skipped).
- Current branch: `dev`, up to date with `origin/dev`.

## What this skill does NOT do

- Does not push anything.
- Does not delete remote branches.
- Does not rebase, merge, or rewrite history.
- Does not touch tags, stashes, or worktrees.
- Does not run tests, CI, or builds.
- Does not reopen issues — only closes ones still `OPEN`.
- Does not close issues whose branch could not be safely deleted.

## Example session

```
User: /cleanup

Claude: Working tree clean. Switching to dev and pulling...
        Pulled 3 new commits. Pruned 2 stale remote refs.

        Cleanup plan:
          1. issue-23-set-up-ci-with-sonarcloud  (merged into dev) — closes issue #23
          2. issue-19-build-account-core         (upstream gone)   — issue #19 already CLOSED
          3. experiment-azure-delta-spike        (merged into dev) — no linked issue

        Delete all 3 branches and close the listed open issues? (yes / no / skip <numbers>)

User: skip 3

Claude: Deleted issue-23-set-up-ci-with-sonarcloud.
        Closed issue #23.
        Deleted issue-19-build-account-core (issue #19 was already closed).
        Kept experiment-azure-delta-spike (per your request).

        Done. On dev, up to date with origin/dev.
```
