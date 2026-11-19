#!/usr/bin/env bash
#
# verify.sh — grade ONE section of lab 1. Everything is in this file.
#
#   ./verify.sh --section dockerfile --path lab-01
#   ./verify.sh --section hardening --path lab-01 --json
#
#   dockerfile   the image builds, the base is pinned, the app answers   section 1
#   hardening    multi-stage, non-root, honest layers                    section 2
#   compose      Postgres health-gated, and the data survives down/up    section 3
#   wiremock     the partner stub answers, and its 500 surfaces as a 502  bonus
#   networks     internal: true holds, and the database has no egress     bonus
#
# Flags: --path DIR · --port N · --json · --keep · --bonus
# Exit 0 = nothing failed. A WARN is a judgement call for the pull request.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECTION=""; WORKDIR=""; JSON="${JSON:-0}"; KEEP="${KEEP:-0}"; BONUS=0
LIB="${LAB01_LIB:-0}"      # 1 = only define the functions, for tests/run.sh

if [ "$LIB" = 0 ]; then
while [ $# -gt 0 ]; do
  case "$1" in
    --section) SECTION="${2:?--section needs a value}"; shift 2 ;;
    --path)    WORKDIR="${2:?--path needs a value}";    shift 2 ;;
    --port)    PORT="${2:?--port needs a value}";       shift 2 ;;
    --json)    JSON=1; shift ;;
    --keep)    KEEP=1; shift ;;
    --bonus)   BONUS=1; shift ;;   # report, never fail: a bonus cannot cost marks
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done
case "$SECTION" in
  dockerfile|hardening|compose|wiremock|networks) : ;;
  "") echo "--section is required: dockerfile | hardening | compose | wiremock | networks" >&2; exit 2 ;;
  *)  echo "unknown section '$SECTION'" >&2; exit 2 ;;
esac

# One lab per folder, so the grader is pointed at a folder rather than the
# repository root. git still resolves from here, which the secret checks need.
if [ -n "$WORKDIR" ]; then
  cd "$WORKDIR" || { echo "no such path: $WORKDIR" >&2; exit 2; }
fi
fi

export JSON KEEP
# shellcheck source=../common/lib.sh
. "$HERE/../common/lib.sh"
# shellcheck source=../common/secrets.sh
. "$HERE/../common/secrets.sh"
[ "$LIB" = 0 ] && trap cleanup EXIT

# ── sections ─────────────────────────────────────────────────────────────────

# Section 1 — a Dockerfile that runs. No Compose: this section is about the image.

section_dockerfile() {
  sect "the files"
  need_file Dockerfile
  need_file .dockerignore
  need_file app.py
  need_file requirements.txt

  sect "the Dockerfile, read"
  if [ ! -f Dockerfile ]; then
    bad "dockerfile" "no Dockerfile"
    return
  fi

  # 1 · the base image must be pinned, or the build stops being reproducible
  local base
  base="$(grep -iE '^[[:space:]]*FROM' Dockerfile | head -1 | awk '{print $2}')"
  case "$base" in
    *:latest) bad "dockerfile:tag" "base uses :latest ($base) — pin a version" ;;
    *:*)      ok  "dockerfile:tag" "base pinned: $base" ;;
    *)        bad "dockerfile:tag" "base has no tag ($base), which means :latest" ;;
  esac

  # 2 · dependencies before source, or every edit reinstalls every package
  local rq src
  rq="$(grep -nE '^[[:space:]]*COPY.*requirements' Dockerfile | head -1 | cut -d: -f1)"
  src="$(grep -nE '^[[:space:]]*COPY.*(app\.py|\. )' Dockerfile | head -1 | cut -d: -f1)"
  if [ -n "$rq" ] && [ -n "$src" ] && [ "$rq" -lt "$src" ]; then
    ok "dockerfile:cacheorder" "requirements copied before the source"
  elif [ -n "$rq" ]; then
    bad "dockerfile:cacheorder" "source copied before requirements — every edit reinstalls pip"
  else
    bad "dockerfile:cacheorder" "no separate COPY of requirements.txt"
  fi

  # 3 · something has to run
  grep -qiE '^[[:space:]]*(CMD|ENTRYPOINT)' Dockerfile \
    && ok "dockerfile:cmd" "has CMD/ENTRYPOINT" \
    || bad "dockerfile:cmd" "no CMD or ENTRYPOINT"

  # 4 · the build context
  if [ -f .dockerignore ]; then
    grep -qE '^\.git/?$' .dockerignore \
      && ok  "dockerignore:git" ".git excluded" \
      || warn "dockerignore:git" ".git is in the build context"
    grep -qE '^\.env$' .dockerignore \
      && ok  "dockerignore:env" ".env excluded" \
      || bad "dockerignore:env" ".env not excluded — it can land in the image"
  fi

  # 5 · does it actually work
  run_image || return
  local v1 v2
  v1="$(visits)"; v2="$(visits)"
  if [ -n "${v2:-}" ] && [ "${v2:-0}" -gt "${v1:-0}" ]; then
    ok "run:visits" "/visits counts up ($v1 -> $v2)"
  else
    bad "run:visits" "/visits does not increment (got '$v1' then '$v2') — is /data writable by your user?"
  fi
}

# Section 2 — multi-stage and non-root: nothing the build needed may ship.

section_hardening() {
  sect "the files"
  need_file Dockerfile
  need_file .dockerignore

  sect "hardening, read"
  if [ ! -f Dockerfile ]; then
    bad "dockerfile" "no Dockerfile"
    return
  fi

  # 1 · root in a container is root on the shared kernel
  if grep -qiE '^[[:space:]]*USER[[:space:]]+' Dockerfile \
     && ! grep -qiE '^[[:space:]]*USER[[:space:]]+(root|0)[[:space:]]*$' Dockerfile; then
    ok "dockerfile:user" "declares a non-root USER"
  else
    bad "dockerfile:user" "no non-root USER — the container runs as root"
  fi

  # 2 · a second FROM is what lets the toolchain stay behind
  local stages
  stages="$(grep -ciE '^[[:space:]]*FROM[[:space:]]' Dockerfile)"
  if [ "${stages:-1}" -ge 2 ]; then
    ok "dockerfile:multistage" "$stages stages — build tooling can stay behind"
  else
    bad "dockerfile:multistage" "single stage — nothing can be left behind"
  fi

  # 3 · apt-get update alone in a layer goes stale and installs old versions
  local stale=0 line
  while IFS= read -r line; do
    case "$line" in
      *"apt-get update"*|*"apt update"*)
        printf '%s' "$line" | grep -q 'install' && continue
        printf '%s' "$line" | grep -q '\\$'    && continue
        stale=1 ;;
    esac
  done < <(grep -iE '^[[:space:]]*RUN' Dockerfile)
  [ "$stale" = 1 ] \
    && bad "dockerfile:aptatomic" "'apt-get update' alone in a layer — a cached index installs stale versions" \
    || ok  "dockerfile:aptatomic" "no orphaned 'apt-get update'"

  # 4 · a cleanup in its own RUN frees nothing: the bytes are in the layer below
  if grep -iE '^[[:space:]]*RUN[[:space:]]+rm[[:space:]]+-rf[[:space:]]+/var/(lib/apt|cache)' Dockerfile >/dev/null 2>&1; then
    bad "dockerfile:cleanuplayer" "'rm -rf /var/...' in its own RUN — the bytes stay in the earlier layer"
  else
    ok "dockerfile:cleanuplayer" "no cleanup stranded in its own layer"
  fi

  # 5 · and the claims, measured on the real image
  run_image || return

  sect "hardening, running"
  local uid sz ly
  uid="$(docker run --rm --entrypoint id "$IMG" -u 2>/dev/null | tr -dc '0-9')"
  if [ -n "${uid:-}" ] && [ "${uid:-0}" -ne 0 ]; then
    ok "run:nonroot" "the process runs as uid $uid"
  elif [ -n "${uid:-}" ]; then
    bad "run:nonroot" "the process runs as root (uid 0)"
  else
    warn "run:nonroot" "could not read the effective uid"
  fi

  if docker run --rm --entrypoint sh "$IMG" -c 'command -v gcc || command -v cc' >/dev/null 2>&1; then
    bad "run:toolchain" "a C compiler ships in the runtime image — multi-stage would leave it behind"
  else
    ok "run:toolchain" "no compiler in the runtime image"
  fi

  sz="$(docker image inspect "$IMG" --format '{{.Size}}' 2>/dev/null)"
  ly="$(docker image inspect "$IMG" --format '{{len .RootFS.Layers}}' 2>/dev/null)"
  log "  ${D}image: $(( ${sz:-0} / 1000000 )) MB in ${ly:-?} layers${N}"
}

# Section 3 — Compose, Postgres and a named volume. The container is disposable;
# the data is not. That claim is tested by destroying the stack and coming back.

section_compose() {
  sect "the files"
  need_file "$COMPOSE"
  need_file .env.example

  check_compose_shape
  [ -f "$COMPOSE" ] || return

  # the two service names are a stated contract, because the checks address them
  local svcs
  svcs="$(docker compose -f "$COMPOSE" config --services 2>/dev/null)"
  printf '%s\n' "$svcs" | grep -qx app \
    && ok  "compose:service-app" "a service named 'app'" \
    || bad "compose:service-app" "no service named 'app' — the brief fixes that name"
  printf '%s\n' "$svcs" | grep -qx db \
    && ok  "compose:service-db" "a service named 'db'" \
    || bad "compose:service-db" "no service named 'db' — the brief fixes that name"

  local dbports
  dbports="$(grep -nE '^[[:space:]]*-[[:space:]]*"?[0-9.]*:?[0-9]*:?5432' "$COMPOSE" || true)"
  if [ -z "$dbports" ]; then
    ok "compose:dbport" "the database port is not published"
  elif printf '%s\n' "$dbports" | grep -qv '127\.0\.0\.1'; then
    bad "compose:dbport" "the database port is published beyond loopback"
  else
    warn "compose:dbport" "database on loopback only — fine for debugging, say so in the pull request"
  fi

  # Ask for the app and nothing else. Compose starts what it depends on, so this is
  # a behavioural test of the dependency graph rather than a grep for depends_on.
  run_stack app || return

  sect "did asking for the app bring the database?"
  if running_services | grep -qx db; then
    ok "stack:graph" "'up app' started the database too — the dependency is declared"
  else
    bad "stack:graph" "'up app' did not start the database — nothing in compose.yaml says the app needs it"
  fi

  sect "the counter lives in Postgres"
  local store v1 v2 before after
  store="$(store_name)"
  [ "$store" = "postgres" ] \
    && ok  "stack:store" "/visits reports store=postgres" \
    || bad "stack:store" "/visits reports store='${store:-?}' — DATABASE_URL is not reaching the app"

  v1="$(visits)"; v2="$(visits)"
  if [ -n "${v2:-}" ] && [ "${v2:-0}" -gt "${v1:-0}" ]; then
    ok "stack:visits" "/visits counts up ($v1 -> $v2)"
  else
    bad "stack:visits" "/visits does not increment (got '$v1' then '$v2')"
  fi

  # The persistence test only means something once the counter is actually reaching
  # the database. Running it anyway would report "no named volume" at a student whose
  # real problem is upstream, and send them to the wrong file.
  if [ -z "${v2:-}" ] || [ "${v2:-0}" -le "${v1:-0}" ]; then
    warn "persist:volume" "not tested — /visits is not counting yet, so fix that first"
    return
  fi

  sect "does the data survive down/up?"
  before="${v2:-0}"
  docker compose -f "$COMPOSE" down >/dev/null 2>&1
  docker compose -f "$COMPOSE" up -d app >/dev/null 2>&1
  if wait_up 90; then
    after="$(visits)"
    if [ -n "${after:-}" ] && [ "${after:-0}" -gt "${before:-0}" ]; then
      ok "persist:volume" "the data survived down/up ($before -> $after)"
    else
      bad "persist:volume" "the data was LOST across down/up ($before -> $after) — no named volume, or mounted at the wrong path"
    fi
  else
    bad "persist:restart" "the stack did not come back up"
  fi
}

# Bonus — the partner API we do not own, replaced by a stub that can fail on demand.

section_wiremock() {
  sect "the files"
  need_file "$COMPOSE"
  check_compose_shape
  [ -f "$COMPOSE" ] || return

  run_stack || return

  sect "the partner stub"
  if curl -sf -m 5 "$BASE/price/MK-II" | grep -q 'price'; then
    ok "stack:price" "/price/MK-II answers from the stub"
  else
    bad "stack:price" "/price/MK-II returned no price — is the partner service up and PARTNER_URL set?"
  fi

  # the thing the real partner would never do for you on request
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$BASE/price/BOOM-1")"
  [ "$code" = "502" ] \
    && ok   "stack:price-fail" "/price/BOOM-1 surfaces the partner's 500 as 502" \
    || warn "stack:price-fail" "/price/BOOM-1 returned $code — the broken-catalog stub may be missing"
}

# Bonus — inbound publishing and outbound egress are different doors. Open one,
# close the other.

section_networks() {
  sect "the files"
  need_file "$COMPOSE"
  check_compose_shape
  [ -f "$COMPOSE" ] || return

  grep -qE '^[[:space:]]*networks:' "$COMPOSE" \
    && ok  "compose:networks" "networks declared" \
    || bad "compose:networks" "no networks: — everything sits on one default bridge"

  grep -q 'internal: true' "$COMPOSE" \
    && ok  "compose:internal" "at least one internal network" \
    || bad "compose:internal" "no internal: true — the database can still reach the internet"

  run_stack || return

  sect "the door that closes"
  # internal: true removes the gateway, so the database cannot resolve or reach
  # anything outside its network. Proven, not asserted.
  if docker compose -f "$COMPOSE" exec -T db sh -c 'timeout 3 getent hosts example.com' >/dev/null 2>&1; then
    bad "net:db-egress" "the database resolved a public name — its network is not internal"
  else
    ok "net:db-egress" "the database cannot reach the internet"
  fi

  if docker compose -f "$COMPOSE" exec -T app sh -c 'timeout 3 getent hosts db' >/dev/null 2>&1; then
    ok "net:app-db" "the app still reaches the database by name"
  else
    bad "net:app-db" "the app cannot resolve 'db' — it is not on the database's network"
  fi
}

# ── run it ───────────────────────────────────────────────────────────────────
[ "$LIB" = 1 ] && return 0

log "${B}catshop lab 1 · section: $SECTION${N}"
"section_$(printf '%s' "$SECTION" | tr - _)"
check_secrets                 # every section, always
rm -f /tmp/b.$$ /tmp/cb.$$ /tmp/cu.$$

emit_report "$SECTION"

# A bonus section reports and exits clean: it can only ever add marks, so a red
# one must not show up as a failed check.
[ "$BONUS" = 1 ] && exit 0
[ "$FAIL" -eq 0 ]
