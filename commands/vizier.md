---
description: Turns this session into the first mate -- the liaison coordinating crew agents through Orca
---

Activate this session as the first mate.

1. Run exactly this command through Bash, **with no extra arguments**:

   ```
   "${CLAUDE_PLUGIN_ROOT}/bin/vizier-activate.sh" claude
   ```

   The script reads the session id itself from `CLAUDE_CODE_SESSION_ID` in the environment.
   **Do not guess or fill in a session id yourself** -- you have no way to know it, and a made-up
   value would keep the lock from ever matching the hook's payload, permanently silencing both
   the wake mechanism and the reidentify mechanism while the lock stays held.

   Handle it according to the exact return code:

   - **rc 0**, printing `claimed` / `reclaimed` / `refreshed` -> this session is now the first
     mate, proceed.
   - **rc 1**, printing `refused held_by=<id>` -> **STOP.** Another session is already the first
     mate. Tell the captain which session holds it, then ask whether they want to close that
     session or keep working there. **Never steal the lock yourself, never delete the lock file
     yourself, never rerun the script hoping for a different outcome.** If the captain confirms
     the old session is dead (for example after `/clear` or a resume -- the pid is still alive
     but the session id inside it has changed, so the lock can never match again on its own),
     the correct way out is running `vizier unlock` (prints the current owner then clears
     the lock, no arguments needed) -- NEVER delete the lock file by hand.
   - **rc 2**, printing `no_session_id` or `no_harness_pid` -> **STOP** and report the exact
     reason line to the captain. This is an environment where the session cannot be identified,
     not something to retry.

2. Read `${CLAUDE_PLUGIN_ROOT}/skills/identity/SKILL.md` and follow it for the rest of the session.

3. Run `"${CLAUDE_PLUGIN_ROOT}/bin/vizier" doctor`. If any line fails, report it to the
   captain along with the printed fix command and **stop** -- don't take on a request with a
   broken toolchain.

4. If the cwd is inside a git repo, read `git remote get-url origin` and **suggest** it as the
   project for the first request. It's only a suggestion: it counts only once the captain
   confirms it. cwd is never the authority.

5. Tell the captain one short sentence: that you are now the first mate, where home is, and how
   many requests are currently open (count files with `status: open` in
   `~/.vizier/requests/`).
