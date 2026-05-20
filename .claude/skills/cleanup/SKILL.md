---
name: cleanup
description: Post-merge branch tidying for this repo. Run after a PR merges to refresh local `dev`, drop stale remote-tracking refs, and delete local branches that have been merged or whose upstream is gone. Pairs with the `/issue` skill — `/issue` creates branches, this skill reaps them. Never touches `dev` or `master`, never force-deletes unmerged work. User-invocable as /cleanup.
---

# Post-merge cleanup

Use this after a successful PR merge to keep the local working copy aligned with `dev` and prune stale branches. Pairs with the `/issue` skill.

## When to use

- The user invokes `/cleanup`.
- A PR was just merged and the user confirms it's safe to tidy up.

Do **not** run this proactively during other work. It's a deliberate end-of-iteration step.

## Hard rules

- **Never** delete `dev` or `master`. Even if `git branch --merged` lists them, skip.
- **Never** use `git branch -D` (force-delete). Only `git branch -d` (safe — refuses if a branch isn't fully merged).
- **Never** `git push --delete`. Remote-branch deletion is the PR merge setting's job, not this skill's.
- **Never** run on a dirty working tree without explicit user consent — uncommitted work could be lost.
- **Confirm before deleting.** Print the planned deletion list and wait for the user's "yes" (or list of exceptions) before any `git branch -d` runs.

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

### Step 4 — Confirm with the user

Print the final candidate list as a numbered review and ask:

> "Delete these N local branches? (yes / no / skip `<numbers>`)"

- If the user says "no", stop here. Report no branches deleted.
- If the user lists exceptions, drop those numbers and continue with the rest.
- If the user says "yes" (or just confirms), proceed to step 5.

### Step 5 — Delete

For each branch in the approved list:

```
git branch -d <branch>
```

If `git branch -d` refuses (branch is not fully merged), do **not** retry with `-D`. Skip it and report:

> "Branch `<X>` has unmerged work — skipped. Use `git branch -D <X>` manually if you're sure."

### Step 6 — Report

Print a short summary:

- N branches deleted (list them).
- M branches skipped (list them with reasons).
- Current branch: `dev`, up to date with `origin/dev`.

## What this skill does NOT do

- Does not push anything.
- Does not delete remote branches.
- Does not rebase, merge, or rewrite history.
- Does not touch tags, stashes, or worktrees.
- Does not run tests, CI, or builds.

## Example session

```
User: /cleanup

Claude: Working tree clean. Switching to dev and pulling...
        Pulled 3 new commits. Pruned 2 stale remote refs.

        Local branches that can be deleted:
          1. issue-23-set-up-ci-with-sonarcloud  (merged into dev)
          2. issue-19-build-account-core         (upstream gone)
          3. experiment-azure-delta-spike        (merged into dev)

        Delete all 3? (yes / no / skip <numbers>)

User: skip 3

Claude: Deleted issue-23-set-up-ci-with-sonarcloud.
        Deleted issue-19-build-account-core.
        Kept experiment-azure-delta-spike (per your request).

        Done. On dev, up to date with origin/dev.
```
