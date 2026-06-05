---
name: cleanup
description: Post-merge branch tidying for this repo. Run after a PR merges to refresh local `dev`, drop stale remote-tracking refs, delete merged branches both locally and on the remote, and close the GitHub issues those branches were tracking. Pairs with the `/issue` skill — `/issue` creates branches, this skill reaps them. Never touches `dev` or `master`, never force-deletes unmerged work. User-invocable as /cleanup.
---

# Post-merge cleanup

Use this after a successful PR merge to keep the local working copy aligned with `dev`, prune stale branches (local and remote), and close the GitHub issues those branches were tracking. Pairs with the `/issue` skill.

## When to use

- The user invokes `/cleanup`.
- A PR was just merged and the user confirms it's safe to tidy up.

Do **not** run this proactively during other work. It's a deliberate end-of-iteration step.

## Hard rules

- **Never** delete `dev` or `master` — neither the local branch nor the remote branch. Even if `git branch --merged` lists them, skip.
- **Never** use `git branch -D` (force-delete). Only `git branch -d` (safe — refuses if a branch isn't fully merged).
- **Delete the remote branch only after its local copy was safely deleted.** Remote deletion (`git push origin --delete <branch>`) applies solely to approved candidate branches whose local `git branch -d` succeeded. If the local delete was refused, leave the remote alone.
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

- **State `OPEN`** → eligible to close after we delete the branch. This is the **normal** case: PRs in this repo merge into `dev`, which is **not** the GitHub default branch (`master`), so a `Closes #N` line does **not** auto-close the issue on merge. A branch that is merged into `dev` therefore almost always still has an `OPEN` issue, and closing it is this skill's job.
- **State `CLOSED`** → nothing to do (already closed manually, or the change reached `master` and GitHub auto-closed it).
- **No matching issue / `gh` errors** → skip the issue side, but still process the branch.

Branches that don't match `issue-<num>-*` (ad-hoc/experiment branches) are processed for deletion only; there's no issue to close.

**Rule of thumb:** if a branch is merged into `dev` (Step 3 category (a)) and tracks an `OPEN` issue, the plan is always to **delete the branch (local + remote) and close the issue**.

### Step 5 — Confirm with the user

Print one combined plan as a numbered review. For each branch show why it qualifies and what will happen to the linked issue:

```
1. issue-23-set-up-ci-with-sonarcloud  (merged into dev) — delete local + remote, close issue #23 "Set up CI with SonarCloud"
2. issue-19-build-account-core         (upstream gone)   — delete local (remote already gone), issue #19 already CLOSED
3. experiment-azure-delta-spike        (merged into dev) — delete local + remote, no linked issue
```

Branch deletion covers **both** the local branch and its `origin` counterpart. Then ask:

> "Delete these N branches (local + remote) and close the listed open issues? (yes / no / skip `<numbers>`)"

- "no" → stop, report nothing deleted/closed.
- skip `<numbers>` → drop those entries, continue with the rest.
- "yes" / confirm → proceed.

### Step 6 — Delete branches (local, then remote)

For each approved branch, delete the local copy first:

```
git branch -d <branch>
```

If `git branch -d` refuses (branch is not fully merged), do **not** retry with `-D`, do **not** delete the remote, and do **not** close the linked issue. Skip and report:

> "Branch `<X>` has unmerged work — skipped (issue #<N> left open). Use `git branch -D <X>` manually if you're sure."

After a **successful** local delete, delete the remote branch:

```
git push origin --delete <branch>
```

Handle the result:

- **Deleted** → note it for the report.
- **`remote ref does not exist`** (the PR merge setting already deleted it, or the branch was in the "upstream gone" category) → treat as already-clean, not a failure.
- **Any other error** (auth, network, protected branch) → report it and move on; the successful local delete and the issue close (Step 7) still stand.

Never run this for `dev` or `master` — they are excluded from candidates in Step 3.

### Step 7 — Close issues whose branch deletion succeeded

For each branch whose **local** delete succeeded in Step 6 AND which has a linked issue still in state `OPEN`:

```
gh issue close <num> --comment "Branch <branch> deleted via /cleanup after PR merged to dev."
```

Gate this on the local delete, not the remote one — a remote-delete hiccup must not block closing the issue. If `gh issue close` fails (network, auth, permission), report the failure and leave the issue alone — the branch deletion still stands.

### Step 8 — Report

Print a short summary:

- N branches deleted locally (list them), and which of those were also deleted on `origin` (vs. already gone).
- M branches skipped (list them with reasons).
- K issues closed (list `#<num>`s, with the merged-PR context if available).
- L issues left open (list `#<num>`s — typically because the branch was skipped).
- Current branch: `dev`, up to date with `origin/dev`.

## What this skill does NOT do

- Does not push commits — the only push it makes is `--delete` of an approved, locally-deleted branch.
- Does not delete the remote `dev` or `master`, nor any remote branch whose local copy was not safely deleted first.
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
          1. issue-23-set-up-ci-with-sonarcloud  (merged into dev) — delete local + remote, close issue #23
          2. issue-19-build-account-core         (upstream gone)   — delete local (remote already gone), issue #19 already CLOSED
          3. experiment-azure-delta-spike        (merged into dev) — delete local + remote, no linked issue

        Delete all 3 branches (local + remote) and close the listed open issues? (yes / no / skip <numbers>)

User: skip 3

Claude: Deleted issue-23-set-up-ci-with-sonarcloud (local + origin).
        Closed issue #23.
        Deleted issue-19-build-account-core locally (origin was already gone; issue #19 was already closed).
        Kept experiment-azure-delta-spike (per your request).

        Done. On dev, up to date with origin/dev.
```