#!/usr/bin/env bash
#
# lib.sh — the plumbing every section shares: counters, output, and the two ways
# of starting the application (a bare image, or the Compose stack).
#
# Sourced by verify.sh. Nothing here knows about any particular section.

# ── results ──────────────────────────────────────────────────────────────────
PASS=0; FAIL=0; WARN=0; RESULTS=()

if [ -t 1 ] && [ "${JSON:-0}" = 0 ]; then
  G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; D=$'\033[2m'; B=$'\033[1m'; N=$'\033[0m'
else
  G=; R=; Y=; D=; B=; N=
fi

log()  { [ "${JSON:-0}" = 1 ] || printf '%s\n' "$*"; }
sect() { log ""; log "${B}$*${N}"; }
ok()   { PASS=$((PASS+1)); RESULTS+=("PASS|$1|$2"); log "  ${G}PASS${N}  $1  ${D}$2${N}"; }
bad()  { FAIL=$((FAIL+1)); RESULTS+=("FAIL|$1|$2"); log "  ${R}FAIL${N}  $1  $2"; }
warn() { WARN=$((WARN+1)); RESULTS+=("WARN|$1|$2"); log "  ${Y}WARN${N}  $1  $2"; }

need_file() { [ -f "$1" ] && ok "file:$1" "present" || bad "file:$1" "missing"; }

# ── the application under test ───────────────────────────────────────────────
COMPOSE="${COMPOSE:-compose.yaml}"
[ -f "$COMPOSE" ] || [ ! -f compose.yml ] || COMPOSE=compose.yml
PORT="${PORT:-8080}"
BASE="http://localhost:${PORT}"
IMG="catshop-verify-$$"
export COMPOSE_PROJECT_NAME="verify-$$"

cleanup() {
  if [ "${KEEP:-0}" = 1 ]; then
    log "${D}left running — docker compose -p $COMPOSE_PROJECT_NAME down -v${N}"
    return
  fi
  docker rm -f "$IMG" >/dev/null 2>&1 || true
  [ -f "$COMPOSE" ] && docker compose -f "$COMPOSE" down -v >/dev/null 2>&1 || true
  docker image rm -f "$IMG" >/dev/null 2>&1 || true
}

wait_up() {  # wait_up <seconds> — poll /health until it answers
  local n="${1:-60}"
  for _ in $(seq 1 "$n"); do
    curl -sf -m 2 "$BASE/health" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

visits() { curl -sf -m 5 "$BASE/visits" | tr -dc '0-9'; }

store_name() {  # which backend /visits reports: file or postgres
  curl -sf -m 5 "$BASE/visits" | tr -d ' "' | sed -n 's/.*store:\([a-z]*\).*/\1/p'
}

# ── starting it: one image, no Compose ───────────────────────────────────────
# Used by the sections that are about the IMAGE. Returns non-zero if the app
# never came up, so the caller can skip checks that would cascade.
run_image() {
  sect "build and run the image"
  if ! docker build -t "$IMG" . >/tmp/b.$$ 2>&1; then
    bad "run:build" "docker build failed"; tail -15 /tmp/b.$$ >&2; return 1
  fi
  ok "run:build" "the image builds"

  if ! docker run -d --name "$IMG" -p "${PORT}:8080" "$IMG" >/dev/null 2>&1; then
    bad "run:start" "docker run failed"; docker logs "$IMG" 2>&1 | tail -15 >&2; return 1
  fi
  ok "run:start" "the container starts"

  if ! wait_up 60; then
    bad "run:health" "no answer on $BASE/health after 60s"
    docker logs "$IMG" 2>&1 | tail -15 >&2; return 1
  fi
  ok "run:health" "/health answers"
  return 0
}

# ── starting it: the Compose stack ───────────────────────────────────────────
# Used by the sections that are about COMPOSITION.
run_stack() {
  sect "build and start the stack"
  [ -f .env ] || { cp .env.example .env 2>/dev/null \
    && warn "run:env" "no .env — copied .env.example for this run"; }

  if ! docker compose -f "$COMPOSE" build >/tmp/cb.$$ 2>&1; then
    bad "stack:build" "compose build failed"; tail -15 /tmp/cb.$$ >&2; return 1
  fi
  ok "stack:build" "the stack builds"

  if ! docker compose -f "$COMPOSE" up -d >/tmp/cu.$$ 2>&1; then
    bad "stack:up" "compose up failed"; tail -15 /tmp/cu.$$ >&2; return 1
  fi
  ok "stack:up" "the stack starts"

  if ! wait_up 90; then
    bad "stack:health" "no answer on $BASE/health after 90s"
    docker compose -f "$COMPOSE" logs --tail 20 >&2; return 1
  fi
  ok "stack:health" "/health answers"
  return 0
}

# ── compose file shape · shared by the compose/wiremock/networks sections ────
check_compose_shape() {
  sect "compose, read"
  # a missing file is reported by the section's own need_file call; reporting it
  # here too would duplicate the check id and double-count the failure
  [ -f "$COMPOSE" ] || return
  docker compose -f "$COMPOSE" config -q >/dev/null 2>&1 \
    && ok "compose:valid" "$COMPOSE parses" \
    || bad "compose:valid" "$COMPOSE does not parse"
}

# ── reporting ────────────────────────────────────────────────────────────────
emit_report() {  # emit_report <section>
  local section="$1" total score r st id msg i first
  total=$((PASS+FAIL)); score=0
  [ "$total" -gt 0 ] && score=$(( PASS * 100 / total ))

  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      printf '## section `%s` — %d pass · %d fail · %d warn\n\n' "$section" "$PASS" "$FAIL" "$WARN"
      printf '| | check | detail |\n|---|---|---|\n'
      for r in "${RESULTS[@]}"; do
        IFS='|' read -r st id msg <<<"$r"
        case "$st" in PASS) i='✅' ;; FAIL) i='❌' ;; *) i='⚠️' ;; esac
        printf '| %s | `%s` | %s |\n' "$i" "$id" "$msg"
      done
    } >> "$GITHUB_STEP_SUMMARY"
  fi

  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    { echo "pass=$PASS"; echo "fail=$FAIL"; echo "warn=$WARN"; echo "score=$score"; } >> "$GITHUB_OUTPUT"
  fi

  if [ "${JSON:-0}" = 1 ]; then
    printf '{"section":"%s","pass":%d,"fail":%d,"warn":%d,"score":%d,"checks":[' \
      "$section" "$PASS" "$FAIL" "$WARN" "$score"
    first=1
    for r in "${RESULTS[@]}"; do
      IFS='|' read -r st id msg <<<"$r"
      [ $first = 1 ] || printf ','; first=0
      printf '{"status":"%s","id":"%s","msg":"%s"}' \
        "$st" "$id" "$(printf '%s' "$msg" | sed 's/"/\\"/g')"
    done
    printf ']}\n'
  else
    log ""
    log "${B}section $section${N}  ${G}$PASS pass${N}  ${R}$FAIL fail${N}  ${Y}$WARN warn${N}"
    if [ "$FAIL" -gt 0 ]; then
      log "${R}Not ready.${N} Fix the FAILs; warnings are judgement calls for the pull request."
    else
      log "${G}Section clean.${N}"
    fi
  fi
}
