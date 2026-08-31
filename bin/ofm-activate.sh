#!/usr/bin/env bash
# Kích hoạt phiên này thành first mate. /firstmate gọi đúng script này.
# In một dòng kết quả; rc 0 = phiên này là first mate, rc 1 = bị từ chối.
set -u

if [ $# -lt 2 ]; then
  printf 'usage: ofm-activate.sh <session_id> <harness>\n' >&2
  exit 2
fi
session_id=$1
harness=$2

LIB="$(cd "$(dirname "$0")/../lib" 2>/dev/null && pwd)" || { printf 'error: lib not found\n' >&2; exit 2; }
# shellcheck source=/dev/null
. "$LIB/ofm-home.sh"

mkdir -p "$(ofm_home)/requests" "$(ofm_home)/projects" || { printf 'error: cannot create home\n' >&2; exit 2; }

pid=$(ofm_harness_pid "$harness")
[ -n "$pid" ] || pid=$PPID

ofm_lock_claim "$session_id" "$harness" "$pid"
