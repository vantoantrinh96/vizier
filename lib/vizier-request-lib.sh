# shellcheck shell=bash
# The Request file: one captain request = one file = one Orca Run.
# Requires lib/vizier-home.sh to be sourced first.
#
# THE FRONTMATTER SHAPE IS SHARED. lib/vizier-wake-lib.sh reads these same
# files to decide which Runs the wake hook waits on. Change a key name here
# and the hook goes silent -- with no error, because a missing key just looks
# like "no open requests". Any change to the keys below must change
# vizier_open_run_ids in the same commit.
#
# FRONTMATTER IS SCOPED, ALWAYS. Every read stops at the closing `---`. A
# request body quotes the captain verbatim, and a captain who writes
# "status: closed" in a sentence must not thereby close the request.

# Transliterate, lowercase, collapse to single dashes, cap, trim dashes.
# Cap first, THEN trim: cutting mid-word can leave a trailing dash, and a
# slug ending in a dash makes an ugly filename that also breaks the
# round-trip in tests.
# macOS iconv is NOT usable here. `iconv -t ASCII//TRANSLIT` fails outright on
# Vietnamese ("illegal byte sequence") and emits a truncated prefix, so
# "sua loi dang nhap" comes out as "ss-a-l-i-ng-nh-p". Measured on the
# captain's machine, 2026-09-01. An explicit table is longer but it is the
# only version that works for the language the captain actually writes in.
_vizier_translit() {  # <text>
  printf '%s' "$1" | sed \
    -e 's/[àáảãạăằắẳẵặâầấẩẫậ]/a/g' -e 's/[ÀÁẢÃẠĂẰẮẲẴẶÂẦẤẨẪẬ]/A/g' \
    -e 's/[èéẻẽẹêềếểễệ]/e/g' -e 's/[ÈÉẺẼẸÊỀẾỂỄỆ]/E/g' \
    -e 's/[ìíỉĩị]/i/g' -e 's/[ÌÍỈĨỊ]/I/g' \
    -e 's/[òóỏõọôồốổỗộơờớởỡợ]/o/g' -e 's/[ÒÓỎÕỌÔỒỐỔỖỘƠỜỚỞỠỢ]/O/g' \
    -e 's/[ùúủũụưừứửữự]/u/g' -e 's/[ÙÚỦŨỤƯỪỨỬỮỰ]/U/g' \
    -e 's/[ỳýỷỹỵ]/y/g' -e 's/[ỲÝỶỸỴ]/Y/g' \
    -e 's/đ/d/g' -e 's/Đ/D/g'
}

vizier_request_slug() {  # <text>
  s=$(_vizier_translit "${1:-}")
  s=$(printf '%s' "$s" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9]\{1,\}/-/g' \
    | cut -c1-60 \
    | sed 's/^-*//; s/-*$//')
  [ -n "$s" ] || s=request
  printf '%s' "$s"
}

vizier_request_path() {  # <slug>
  printf '%s/%s.md' "$(vizier_requests_dir)" "$1"
}

vizier_request_create() {  # <slug> <run_id> <project> <project_id> <host> <body>
  f=$(vizier_request_path "$1")
  [ -e "$f" ] && return 1
  mkdir -p "$(vizier_requests_dir)" || return 1
  # Written to a temp file and moved into place: a half-written frontmatter
  # read by the wake hook mid-write would parse as "not open".
  t=$(mktemp "${TMPDIR:-/tmp}/vizier-req.XXXXXX") || return 1
  {
    printf -- '---\n'
    printf 'run_id: %s\n' "$2"
    printf 'project: %s\n' "$3"
    printf 'project_id: %s\n' "$4"
    printf 'host: %s\n' "$5"
    printf 'status: open\n'
    printf 'opened: %s\n' "$(date +%Y-%m-%d)"
    printf -- '---\n'
    printf '%s\n' "$6"
  } > "$t" || { rm -f "$t"; return 1; }
  mv "$t" "$f"
}

# Print the frontmatter only: everything between the first `---` and the next.
_vizier_request_frontmatter() {  # <slug>
  f=$(vizier_request_path "$1")
  [ -r "$f" ] || return 1
  tr -d '\r' < "$f" | awk 'NR==1 && $0=="---" {inside=1; next} inside && $0=="---" {exit} inside'
}

vizier_request_get() {  # <slug> <key>
  _vizier_request_frontmatter "$1" 2>/dev/null \
    | sed -n "s/^$2: *//p" | head -n 1
}

vizier_request_set() {  # <slug> <key> <value>
  f=$(vizier_request_path "$1")
  [ -w "$f" ] || return 1
  t=$(mktemp "${TMPDIR:-/tmp}/vizier-req.XXXXXX") || return 1
  # awk, not sed -i: BSD and GNU disagree on -i, and the value may contain
  # slashes (a project_id does). Passing the value as an awk variable means
  # it is never re-parsed as a pattern.
  tr -d '\r' < "$f" | awk -v k="$2" -v v="$3" '
    NR==1 && $0=="---" { inside=1; print; next }
    inside && $0=="---" { inside=0; print; next }
    inside && index($0, k ":") == 1 { print k ": " v; next }
    { print }
  ' > "$t" || { rm -f "$t"; return 1; }
  mv "$t" "$f"
}

vizier_request_note() {  # <slug> <line>
  f=$(vizier_request_path "$1")
  [ -w "$f" ] || return 1
  printf '%s\n' "$2" >> "$f"
}

vizier_request_close() {  # <slug>
  vizier_request_set "$1" status closed
}

vizier_request_open_slugs() {
  d=$(vizier_requests_dir)
  [ -d "$d" ] || return 0
  for f in "$d"/*.md; do
    [ -e "$f" ] || continue
    s=$(basename "$f" .md)
    [ "$(vizier_request_get "$s" status)" = "open" ] && printf '%s\n' "$s"
  done
  return 0
}
