#!/usr/bin/env bash
#
# verify.sh — grade ONE section of lab 1.
#
#   ./verify.sh --section dockerfile --path lab-01
#   ./verify.sh --section compose    --path lab-01 --json
#   ./verify.sh --section networks   --path lab-01 --keep
#
# Sections, in the order the lab teaches them:
#
#   dockerfile   a working image for the provided app      section 1 · required
#   hardening    multi-stage, non-root, honest layers      section 2 · required
#   compose      Compose + Postgres + a named volume       section 3 · required
#   wiremock     the partner stub answers                   bonus
#   networks     explicit networks, egress closed           bonus
#
# Each section lives in its own file under sections/. The shared plumbing — counters,
# output, and the two ways of starting the app — is in lib.sh.
#
# Flags:
#   --path DIR   the lab folder to grade, relative to the repository root
#   --port N     the host port the app must be published on (default 8080)
#   --json       machine-readable output
#   --keep       leave the stack running afterwards, for inspection
#
# Exit 0 = nothing failed. A WARN is a judgement call to explain in the pull request.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECTIONS="$HERE/sections"

SECTION=""; WORKDIR=""; JSON=0; KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --section) SECTION="${2:?--section needs a value}"; shift 2 ;;
    --path)    WORKDIR="${2:?--path needs a value}";    shift 2 ;;
    --port)    PORT="${2:?--port needs a value}";       shift 2 ;;
    --json)    JSON=1; shift ;;
    --keep)    KEEP=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$SECTION" ]; then
  echo "--section is required. Available:" >&2
  for f in "$SECTIONS"/*.sh; do
    echo "  $(basename "$f" .sh)" >&2
  done
  exit 2
fi
if [ ! -f "$SECTIONS/$SECTION.sh" ]; then
  echo "unknown section '$SECTION'" >&2; exit 2
fi

# One lab per folder, so the grader is pointed at a folder rather than the repository
# root. git still resolves from here, which is what the secret checks rely on.
if [ -n "$WORKDIR" ]; then
  cd "$WORKDIR" || { echo "no such path: $WORKDIR" >&2; exit 2; }
fi

export JSON KEEP
# shellcheck source=../../common/lib.sh
. "$HERE/../../common/lib.sh"          # needs JSON/KEEP/PORT set, and the working directory final
trap cleanup EXIT

# shellcheck source=/dev/null
. "$SECTIONS/$SECTION.sh"     # defines section_run
# shellcheck source=../../common/secrets.sh
. "$HERE/../../common/secrets.sh"      # defines check_secrets

log "${B}catshop lab 1 · section: $SECTION${N}"
section_run
check_secrets                 # every section, always
rm -f /tmp/b.$$ /tmp/cb.$$ /tmp/cu.$$

emit_report "$SECTION"
[ "$FAIL" -eq 0 ]
