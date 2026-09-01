---
name: request
description: Open or close a Request. Use when the captain states a new request, or says a request is done.
---

# Request lifecycle

**One captain request = one Request = one Orca Run.** Not one feature — "fix
the flaky test then add dark mode" is *one* request with two tasks.

Source the libraries first:

```bash
. "$VIZIER_DIST/lib/vizier-home.sh"
. "$VIZIER_DIST/lib/vizier-request-lib.sh"
. "$VIZIER_DIST/lib/vizier-routing-lib.sh"
```

## Opening

### 1. Identify the project

The working directory is a **suggestion, never authority**. Read
`git remote get-url origin` if there is one, propose the project, and wait for
the captain to confirm. Record both names: the short one (`platform`, which
names `projects/platform.md`) and Orca's (`github:owner/repo`).

### 2. Route

```bash
vizier_routing_table "<project_id>"
```

Each row is `name<TAB>health<TAB>setup<TAB>eligible`. Add the running-worker
count per host from `orca worktree ps --json`. Present every host with its
reason, not only the eligible ones — a captain who cannot see why the Mac mini
is missing will ask.

### 3. Ask the captain to choose — **exactly once**

This is the request's only mandatory question. Every task in this request
inherits the answer: retries, review fixes, spawned work. Never ask again.

- The captain picks a host with no `ready` setup → propose
  `orca project setup-clone` and run it **only after they agree**.
- No host is eligible → say so and stop. Do not fall back to local.
- **Never silently move work to another host.** Not at open, not later.

### 4. Create the Run and the file

```bash
run=$(orca orchestration run-create --objective "<the captain's request>" --json | jq -r '.result.run.id')
slug=$(vizier_request_slug "<short title>")
vizier_request_create "$slug" "$run" "<project>" "<project_id>" "<host>" "<the captain's words, verbatim>"
```

Quote the captain verbatim in the body. Later tasks are briefed from it, and a
paraphrase drifts.

## Closing

Only when **the captain says** the request is complete.

1. List the request's dispatches that are still holding a terminal:
   `orca orchestration worker-list --run <run_id> --json`.
2. For each: `orca orchestration worker-release --dispatch <id> --json`.
   A receipt saying `release_pending` or `release_unknown` → do exactly what
   the receipt says. **Substituting `terminal close` is forbidden.**
3. `vizier_request_close "$slug"`.

Host pinning ends here. The next request routes from scratch.

## Hard rules

- The host is asked **exactly once** per request, and never re-asked.
- A pinned host that dies mid-flight → **stop and report**. Changing a
  request's host is the captain's decision, not yours.
- Never close a request the captain has not called complete.
