#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"
vizier_test_setup
. "$VIZIER_TEST_REPO/lib/vizier-home.sh"
. "$VIZIER_TEST_REPO/lib/vizier-wake-lib.sh"
. "$VIZIER_TEST_REPO/lib/vizier-request-lib.sh"

# --- slugs ----------------------------------------------------------------
assert_eq "$(vizier_request_slug 'Fix the flaky test then add dark mode')" \
          "fix-the-flaky-test-then-add-dark-mode" "words become a kebab slug"
assert_eq "$(vizier_request_slug '  Trailing / slashes ../ and dots.  ')" \
          "trailing-slashes-and-dots" "path characters cannot survive a slug"
assert_eq "$(vizier_request_slug 'sửa lỗi đăng nhập')" "sua-loi-dang-nhap" \
          "non-ASCII is transliterated, not dropped to nothing"
assert_eq "$(vizier_request_slug '')" "request" "an empty title still yields a usable name"
# 60 words of "word " cut at 60 chars lands exactly on a dash (12 x "word-"),
# and trimming it leaves 59. Measured, not assumed -- an assertion of 60 here
# would fail against correct code.
long=$(vizier_request_slug "$(printf 'word %.0s' $(seq 1 60))")
assert_eq "${#long}" "59" "slug is capped at 60 characters, then trimmed"
assert_eq "$(printf '%s' "$long" | sed 's/.*\(.\)$/\1/')" "d" "cap never leaves a trailing dash"

# --- create ---------------------------------------------------------------
vizier_request_create dark-mode run-1 platform github:acme/platform local "Add dark mode"
f="$(vizier_request_path dark-mode)"
assert_eq "$(test -f "$f" && echo yes)" "yes" "file created"
assert_eq "$(vizier_request_get dark-mode run_id)" "run-1" "run_id round-trips"
assert_eq "$(vizier_request_get dark-mode project)" "platform" "project round-trips"
assert_eq "$(vizier_request_get dark-mode project_id)" "github:acme/platform" "project_id keeps its colon"
assert_eq "$(vizier_request_get dark-mode host)" "local" "host round-trips"
assert_eq "$(vizier_request_get dark-mode status)" "open" "new requests are open"
assert_contains "$(cat "$f")" "Add dark mode" "body preserved"

# the wake hook's reader must accept what we wrote -- this is the whole point
assert_eq "$(vizier_open_run_ids)" "run-1" "wake-lib sees the request we wrote"

# --- create is not allowed to clobber -------------------------------------
vizier_request_create dark-mode run-9 other github:acme/other local "different" 2>/dev/null
assert_eq "$?" "1" "create refuses an existing slug"
assert_eq "$(vizier_request_get dark-mode run_id)" "run-1" "refused create changed nothing"

# --- get is frontmatter-scoped --------------------------------------------
vizier_request_note dark-mode "The captain said status: closed in passing."
assert_eq "$(vizier_request_get dark-mode status)" "open" "a body line never answers a frontmatter query"
assert_eq "$(vizier_open_run_ids)" "run-1" "and never closes the request either"

# --- set / close ----------------------------------------------------------
vizier_request_set dark-mode host "Mac mini"
assert_eq "$(vizier_request_get dark-mode host)" "Mac mini" "a value with a space survives"
assert_eq "$(grep -c '^host:' "$f")" "1" "set replaces, never appends a second key"

# --- library calls must never clobber a caller's own variables ------------
# The reviewer found this: every function used to assign to bare globals
# named f, t, s, d -- exactly the short names a caller reaches for too. Set
# sentinels and call several library functions in between; if any leaks
# through as a bare global, the sentinel gets silently overwritten.
f="caller-owns-this-f"
s="caller-owns-this-s"
vizier_request_create sentinel-check run-9 sentproj sent:proj local "sentinel body" >/dev/null
vizier_request_get sentinel-check status >/dev/null
vizier_request_set sentinel-check host other >/dev/null
vizier_request_open_slugs >/dev/null
vizier_request_close sentinel-check >/dev/null
assert_eq "$f" "caller-owns-this-f" "library calls never clobber a caller's own \$f"
assert_eq "$s" "caller-owns-this-s" "library calls never clobber a caller's own \$s"

vizier_request_create login run-2 platform github:acme/platform local "Fix login"
assert_eq "$(vizier_request_open_slugs | sort | tr '\n' ' ')" "dark-mode login " "both open"
vizier_request_close dark-mode
assert_eq "$(vizier_request_get dark-mode status)" "closed" "closed"
assert_eq "$(vizier_request_open_slugs)" "login" "closed request drops out"
assert_eq "$(vizier_open_run_ids)" "run-2" "and the hook stops waiting on its Run"

# --- CRLF tolerance, matching wake-lib ------------------------------------
printf -- '---\r\nrun_id: run-3\r\nproject: p\r\nproject_id: x\r\nhost: local\r\nstatus: open\r\nopened: 2026-09-01\r\n---\r\nbody\r\n' > "$(vizier_request_path crlf)"
assert_eq "$(vizier_request_get crlf run_id)" "run-3" "CRLF file reads cleanly"
assert_contains "$(vizier_request_open_slugs)" "crlf" "CRLF request counts as open"

# --- slug_for_run: the reverse lookup supervise/delivery use to translate a
# wake event's run_id (all a wake message ever carries) back to the request
# file that names it ---------------------------------------------------------
vizier_request_create run-lookup run-42 proj proj-id local "for slug_for_run"
assert_eq "$(vizier_request_slug_for_run run-42)" "run-lookup" "matches the open request holding that run_id"
assert_eq "$(vizier_request_slug_for_run run-does-not-exist)" "" "no match -> empty, not an error"
vizier_request_close run-lookup
assert_eq "$(vizier_request_slug_for_run run-42)" "" "a closed request's run_id no longer resolves"

# must not clobber a caller's own $s either -- same reviewer-found class of
# bug as the sentinel check above, this function has its own local $s
s="caller-owns-this-s-2"
vizier_request_slug_for_run run-2 >/dev/null
assert_eq "$s" "caller-owns-this-s-2" "vizier_request_slug_for_run never clobbers a caller's own \$s"

vizier_test_teardown
vizier_test_report
