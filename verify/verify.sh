#!/usr/bin/env bash
#
# verify.sh — grade ONE section of a catshop lab.
#
#   ./verify.sh --section dockerfile --path lab-01
#   ./verify.sh --section hardening --json
#   ./verify.sh --section compose --keep
#
# --path is the lab folder to grade, relative to the repository root. One lab per
# folder, so lab 1 stays frozen and graded while lab 4 is being written.
#
# Sections:
#   dockerfile   a working image for the provided app          (lab 1 · section 1)
#   hardening    multi-stage, non-root, honest layers          (lab 1 · section 2)
#   compose      Compose + Postgres + a named volume           (lab 1 · section 3)
#   wiremock     the partner stub answers                      (lab 1 · bonus)
#   networks     explicit networks, egress closed              (lab 1 · bonus)
#
# The secret checks run in EVERY section: a leaked .env is never bonus.
#
# Exit 0 = no FAILs. A WARN is a judgement call to explain in the pull request.
set -uo pipefail

SECTION=""; JSON=0; KEEP=0; PORT="${PORT:-8080}"; WORKDIR=""
while [ $# -gt 0 ]; do case "$1" in
  --section) SECTION="${2:?--section needs a value}"; shift 2 ;;
  --path)    WORKDIR="${2:?--path needs a value}"; shift 2 ;;
  --json)    JSON=1; shift ;;
  --keep)    KEEP=1; shift ;;
  --port)    PORT="${2:?}"; shift 2 ;;
  -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
  *) echo "unknown flag: $1" >&2; exit 2 ;;
esac; done

# One lab per folder, so the grader is pointed at a folder rather than the repo root.
# git still resolves from here, which is what the secret checks rely on.
if [ -n "$WORKDIR" ]; then
  cd "$WORKDIR" || { echo "no such path: $WORKDIR" >&2; exit 2; }
fi

case "$SECTION" in
  dockerfile|hardening|compose|wiremock|networks) ;;
  "") echo "--section is required. One of: dockerfile hardening compose wiremock networks" >&2; exit 2 ;;
  *)  echo "unknown section '$SECTION'" >&2; exit 2 ;;
esac

if [ -t 1 ] && [ "$JSON" = 0 ]; then G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; D=$'\033[2m'; B=$'\033[1m'; N=$'\033[0m'
else G=; R=; Y=; D=; B=; N=; fi

PASS=0; FAIL=0; WARN=0; RESULTS=()
COMPOSE="${COMPOSE:-compose.yaml}"
[ -f "$COMPOSE" ] || [ ! -f compose.yml ] || COMPOSE=compose.yml
BASE="http://localhost:${PORT}"
IMG="catshop-verify-$$"
export COMPOSE_PROJECT_NAME="verify-$$"

log()  { [ "$JSON" = 1 ] || printf '%s\n' "$*"; }
ok()   { PASS=$((PASS+1)); RESULTS+=("PASS|$1|$2"); log "  ${G}PASS${N}  $1  ${D}$2${N}"; }
bad()  { FAIL=$((FAIL+1)); RESULTS+=("FAIL|$1|$2"); log "  ${R}FAIL${N}  $1  $2"; }
warn() { WARN=$((WARN+1)); RESULTS+=("WARN|$1|$2"); log "  ${Y}WARN${N}  $1  $2"; }
sect() { log ""; log "${B}$*${N}"; }

cleanup() {
  [ "$KEEP" = 1 ] && { log "${D}left running — docker compose -p $COMPOSE_PROJECT_NAME down -v${N}"; return; }
  docker rm -f "$IMG" >/dev/null 2>&1 || true
  [ -f "$COMPOSE" ] && docker compose -f "$COMPOSE" down -v >/dev/null 2>&1 || true
  docker image rm -f "$IMG" >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_up() {  # wait_up <seconds>
  for _ in $(seq 1 "${1:-60}"); do
    curl -sf -m 2 "$BASE/health" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}
visits() { curl -sf -m 5 "$BASE/visits" | tr -dc '0-9'; }

# ── the files every section needs ────────────────────────────────────────────
need_file() { [ -f "$1" ] && ok "file:$1" "present" || bad "file:$1" "missing"; }

# ── secrets · run in every section ───────────────────────────────────────────
check_secrets() {
  sect "secrets"
  if git rev-parse --git-dir >/dev/null 2>&1; then
    git ls-files --error-unmatch .env >/dev/null 2>&1 \
      && bad "secret:env-tracked" ".env is COMMITTED — remove it and rotate the value" \
      || ok  "secret:env-tracked" ".env is not tracked"
    git log --all --name-only --pretty=format: 2>/dev/null | sort -u | grep -qx '.env' \
      && bad "secret:env-history" ".env appears in git HISTORY" \
      || ok  "secret:env-history" ".env never committed"
    # ask git, rather than grepping one .gitignore: the rule may live in any of
    # them, or in .git/info/exclude, and the student may run this from a subdirectory
    if git check-ignore -q .env 2>/dev/null; then
      ok "secret:gitignore" ".env is git-ignored"
    else
      bad "secret:gitignore" ".env is not ignored by git — add it to .gitignore"
    fi
  else
    warn "secret:git" "not a git repository"
  fi
  if [ -f Dockerfile ]; then
    # comments are stripped first: "nothing secret is baked in here" is documentation,
    # not a leak. What we are looking for is an assignment with a literal value.
    if grep -vE '^[[:space:]]*#' Dockerfile \
       | grep -qiE '(password|secret|api[_-]?key|token)[[:space:]]*=[[:space:]]*[^$[:space:]]'; then
      bad "secret:dockerfile" "a secret-looking value is assigned in the Dockerfile"
    else
      ok "secret:dockerfile" "no secrets baked into the Dockerfile"
    fi
  fi
  if [ -f "$COMPOSE" ]; then
    if grep -nE '(PASSWORD|SECRET)[: =]+[^$#[:space:]]' "$COMPOSE" | grep -vq '\${'; then
      bad "secret:compose" "a literal password in $COMPOSE — use \${POSTGRES_PASSWORD} and .env"
    else
      ok "secret:compose" "no literal passwords in $COMPOSE"
    fi
  fi
}

# ── static Dockerfile checks ─────────────────────────────────────────────────
check_dockerfile_static() {
  sect "the Dockerfile, read"
  [ -f Dockerfile ] || { bad "dockerfile" "no Dockerfile"; return; }

  base="$(grep -iE '^[[:space:]]*FROM' Dockerfile | head -1 | awk '{print $2}')"
  case "$base" in
    *:latest) bad "dockerfile:tag" "base uses :latest ($base) — pin a version" ;;
    *:*)      ok  "dockerfile:tag" "base pinned: $base" ;;
    *)        bad "dockerfile:tag" "base has no tag ($base), which means :latest" ;;
  esac

  rq="$(grep -nE '^[[:space:]]*COPY.*requirements' Dockerfile | head -1 | cut -d: -f1)"
  src="$(grep -nE '^[[:space:]]*COPY.*(app\.py|\. )' Dockerfile | head -1 | cut -d: -f1)"
  if [ -n "$rq" ] && [ -n "$src" ] && [ "$rq" -lt "$src" ]; then
    ok "dockerfile:cacheorder" "requirements copied before the source"
  elif [ -n "$rq" ]; then
    bad "dockerfile:cacheorder" "source copied before requirements — every edit reinstalls pip"
  else
    bad "dockerfile:cacheorder" "no separate COPY of requirements.txt"
  fi

  grep -qiE '^[[:space:]]*(CMD|ENTRYPOINT)' Dockerfile \
    && ok "dockerfile:cmd" "has CMD/ENTRYPOINT" || bad "dockerfile:cmd" "no CMD or ENTRYPOINT"

  if [ -f .dockerignore ]; then
    grep -qE '^\.git/?$' .dockerignore && ok "dockerignore:git" ".git excluded" \
                                       || warn "dockerignore:git" ".git is in the build context"
    grep -qE '^\.env$' .dockerignore && ok "dockerignore:env" ".env excluded" \
                                     || bad "dockerignore:env" ".env not excluded — it can land in the image"
  fi
}

check_hardening_static() {
  sect "hardening, read"
  [ -f Dockerfile ] || { bad "dockerfile" "no Dockerfile"; return; }

  if grep -qiE '^[[:space:]]*USER[[:space:]]+' Dockerfile \
     && ! grep -qiE '^[[:space:]]*USER[[:space:]]+(root|0)[[:space:]]*$' Dockerfile; then
    ok "dockerfile:user" "declares a non-root USER"
  else
    bad "dockerfile:user" "no non-root USER — the container runs as root"
  fi

  stages="$(grep -ciE '^[[:space:]]*FROM[[:space:]]' Dockerfile)"
  if [ "${stages:-1}" -ge 2 ]; then
    ok "dockerfile:multistage" "$stages stages — build tooling can stay behind"
  else
    bad "dockerfile:multistage" "single stage — nothing can be left behind"
  fi

  stale=0
  while IFS= read -r line; do
    case "$line" in *"apt-get update"*|*"apt update"*)
      printf '%s' "$line" | grep -q 'install' && continue
      printf '%s' "$line" | grep -q '\\$'    && continue
      stale=1 ;;
    esac
  done < <(grep -iE '^[[:space:]]*RUN' Dockerfile)
  [ "$stale" = 1 ] \
    && bad "dockerfile:aptatomic" "'apt-get update' alone in a layer — a cached index installs stale versions" \
    || ok  "dockerfile:aptatomic" "no orphaned 'apt-get update'"

  if grep -iE '^[[:space:]]*RUN[[:space:]]+rm[[:space:]]+-rf[[:space:]]+/var/(lib/apt|cache)' Dockerfile >/dev/null 2>&1; then
    bad "dockerfile:cleanuplayer" "'rm -rf /var/...' in its own RUN — the bytes stay in the earlier layer"
  else
    ok "dockerfile:cleanuplayer" "no cleanup stranded in its own layer"
  fi
}

# ── compose shape ────────────────────────────────────────────────────────────
check_compose_static() {
  sect "compose, read"
  [ -f "$COMPOSE" ] || { bad "file:$COMPOSE" "missing"; return; }
  docker compose -f "$COMPOSE" config -q >/dev/null 2>&1 \
    && ok "compose:valid" "$COMPOSE parses" || bad "compose:valid" "$COMPOSE does not parse"
  grep -qE '^[[:space:]]*volumes:' "$COMPOSE" \
    && ok "compose:volumes" "volumes declared" || bad "compose:volumes" "no volumes: — the data dies with the container"
  grep -q 'healthcheck:' "$COMPOSE" \
    && ok "compose:healthcheck" "healthcheck present" || bad "compose:healthcheck" "no healthcheck on the database"
  grep -q 'service_healthy' "$COMPOSE" \
    && ok "compose:gate" "depends_on gated on service_healthy" \
    || warn "compose:gate" "no service_healthy gate — the app must then retry, and ours does"
  dbports="$(grep -nE '^[[:space:]]*-[[:space:]]*"?[0-9.]*:?[0-9]*:?5432' "$COMPOSE" || true)"
  if [ -z "$dbports" ]; then ok "compose:dbport" "the database port is not published"
  elif printf '%s\n' "$dbports" | grep -qv '127\.0\.0\.1'; then
    bad "compose:dbport" "the database port is published beyond loopback"
  else
    warn "compose:dbport" "database on loopback only — fine for debugging, say so in the pull request"
  fi
}

# ── runtime: a single image, no Compose ──────────────────────────────────────
run_image() {
  sect "build and run the image"
  docker build -t "$IMG" . >/tmp/b.$$ 2>&1 \
    && ok "run:build" "the image builds" \
    || { bad "run:build" "docker build failed"; tail -15 /tmp/b.$$ >&2; return 1; }

  docker run -d --name "$IMG" -p "${PORT}:8080" "$IMG" >/dev/null 2>&1 \
    && ok "run:start" "the container starts" \
    || { bad "run:start" "docker run failed"; docker logs "$IMG" 2>&1 | tail -15 >&2; return 1; }

  wait_up 60 && ok "run:health" "/health answers" \
    || { bad "run:health" "no answer on $BASE/health after 60s"; docker logs "$IMG" 2>&1 | tail -15 >&2; return 1; }

  v1="$(visits)"; v2="$(visits)"
  if [ -n "${v2:-}" ] && [ "${v2:-0}" -gt "${v1:-0}" ]; then
    ok "run:visits" "/visits counts up ($v1 -> $v2)"
  else
    bad "run:visits" "/visits does not increment (got '$v1' then '$v2') — is /data writable by your user?"
  fi
  return 0
}

check_runtime_hardening() {
  sect "hardening, running"
  uid="$(docker run --rm "$IMG" id -u 2>/dev/null | tr -dc '0-9')"
  if [ -n "${uid:-}" ] && [ "${uid:-0}" -ne 0 ]; then ok "run:nonroot" "the process runs as uid $uid"
  elif [ -n "${uid:-}" ]; then bad "run:nonroot" "the process runs as root (uid 0)"
  else warn "run:nonroot" "could not read the effective uid"; fi

  if docker run --rm --entrypoint sh "$IMG" -c 'command -v gcc || command -v cc' >/dev/null 2>&1; then
    bad "run:toolchain" "a C compiler ships in the runtime image — multi-stage would leave it behind"
  else
    ok "run:toolchain" "no compiler in the runtime image"
  fi

  sz="$(docker image inspect "$IMG" --format '{{.Size}}' 2>/dev/null)"
  ly="$(docker image inspect "$IMG" --format '{{len .RootFS.Layers}}' 2>/dev/null)"
  log "  ${D}image: $(( ${sz:-0} / 1000000 )) MB in ${ly:-?} layers${N}"
}

# ── runtime: the Compose stack ───────────────────────────────────────────────
run_stack() {
  sect "build and start the stack"
  [ -f .env ] || { cp .env.example .env 2>/dev/null && warn "run:env" "no .env — copied .env.example for this run"; }
  docker compose -f "$COMPOSE" build >/tmp/cb.$$ 2>&1 \
    && ok "stack:build" "the stack builds" \
    || { bad "stack:build" "compose build failed"; tail -15 /tmp/cb.$$ >&2; return 1; }
  docker compose -f "$COMPOSE" up -d >/tmp/cu.$$ 2>&1 \
    && ok "stack:up" "the stack starts" \
    || { bad "stack:up" "compose up failed"; tail -15 /tmp/cu.$$ >&2; return 1; }
  wait_up 90 && ok "stack:health" "/health answers" \
    || { bad "stack:health" "no answer on $BASE/health after 90s"
         docker compose -f "$COMPOSE" logs --tail 20 >&2; return 1; }
  return 0
}

check_postgres_backed() {
  sect "the counter lives in Postgres"
  store="$(curl -sf -m 5 "$BASE/visits" | tr -d ' "' | sed -n 's/.*store:\([a-z]*\).*/\1/p')"
  [ "$store" = "postgres" ] \
    && ok "stack:store" "/visits reports store=postgres" \
    || bad "stack:store" "/visits reports store='${store:-?}' — DATABASE_URL is not reaching the app"
  v1="$(visits)"; v2="$(visits)"
  [ -n "${v2:-}" ] && [ "${v2:-0}" -gt "${v1:-0}" ] \
    && ok "stack:visits" "/visits counts up ($v1 -> $v2)" \
    || bad "stack:visits" "/visits does not increment (got '$v1' then '$v2')"
  echo "${v2:-0}" > /tmp/v2.$$
}

check_persistence() {
  sect "does the data survive down/up?"
  before="$(cat /tmp/v2.$$ 2>/dev/null || echo 0)"
  docker compose -f "$COMPOSE" down >/dev/null 2>&1
  docker compose -f "$COMPOSE" up -d >/dev/null 2>&1
  if wait_up 90; then
    after="$(visits)"
    [ -n "${after:-}" ] && [ "${after:-0}" -gt "${before:-0}" ] \
      && ok  "persist:volume" "the data survived down/up ($before -> $after)" \
      || bad "persist:volume" "the data was LOST across down/up ($before -> $after) — no named volume, or mounted at the wrong path"
  else
    bad "persist:restart" "the stack did not come back up"
  fi
}

check_wiremock() {
  sect "the partner stub"
  if curl -sf -m 5 "$BASE/price/MK-II" | grep -q 'price'; then
    ok "stack:price" "/price/MK-II answers from the stub"
  else
    bad "stack:price" "/price/MK-II returned no price — is the partner service up and PARTNER_URL set?"
  fi
  code="$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$BASE/price/BOOM-1")"
  [ "$code" = "502" ] \
    && ok   "stack:price-fail" "/price/BOOM-1 surfaces the partner's 500 as 502" \
    || warn "stack:price-fail" "/price/BOOM-1 returned $code — the broken-catalog stub may be missing"
}

check_networks() {
  sect "networks, and the door that closes"
  grep -qE '^[[:space:]]*networks:' "$COMPOSE" \
    && ok "compose:networks" "networks declared" \
    || bad "compose:networks" "no networks: — everything sits on one default bridge"
  grep -q 'internal: true' "$COMPOSE" \
    && ok "compose:internal" "at least one internal network" \
    || bad "compose:internal" "no internal: true — the database can still reach the internet"
  if docker compose -f "$COMPOSE" exec -T db sh -c 'timeout 3 getent hosts example.com' >/dev/null 2>&1; then
    bad "net:db-egress" "the database resolved a public name — its network is not internal"
  else
    ok "net:db-egress" "the database cannot reach the internet"
  fi
}

# ── run the requested section ────────────────────────────────────────────────
log "${B}catshop · section: $SECTION${N}"
case "$SECTION" in
  dockerfile)
    sect "the files"
    need_file Dockerfile; need_file .dockerignore; need_file app.py; need_file requirements.txt
    check_dockerfile_static
    run_image
    ;;
  hardening)
    sect "the files"
    need_file Dockerfile; need_file .dockerignore
    check_hardening_static
    run_image && check_runtime_hardening
    ;;
  compose)
    sect "the files"
    need_file "$COMPOSE"; need_file .env.example
    check_compose_static
    if run_stack; then check_postgres_backed; check_persistence; fi
    ;;
  wiremock)
    check_compose_static
    run_stack && check_wiremock
    ;;
  networks)
    check_compose_static
    run_stack && check_networks
    ;;
esac
check_secrets
rm -f /tmp/b.$$ /tmp/cb.$$ /tmp/cu.$$ /tmp/v2.$$

# ── report ───────────────────────────────────────────────────────────────────
TOTAL=$((PASS+FAIL))
SCORE=0; [ "$TOTAL" -gt 0 ] && SCORE=$(( PASS * 100 / TOTAL ))

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    printf '## section `%s` — %d pass · %d fail · %d warn\n\n' "$SECTION" "$PASS" "$FAIL" "$WARN"
    printf '| | check | detail |\n|---|---|---|\n'
    for r in "${RESULTS[@]}"; do IFS='|' read -r st id msg <<<"$r"
      case "$st" in PASS) i='✅' ;; FAIL) i='❌' ;; *) i='⚠️' ;; esac
      printf '| %s | `%s` | %s |\n' "$i" "$id" "$msg"
    done
  } >> "$GITHUB_STEP_SUMMARY"
fi
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  { echo "pass=$PASS"; echo "fail=$FAIL"; echo "warn=$WARN"; echo "score=$SCORE"; } >> "$GITHUB_OUTPUT"
fi

if [ "$JSON" = 1 ]; then
  printf '{"section":"%s","pass":%d,"fail":%d,"warn":%d,"score":%d,"checks":[' "$SECTION" "$PASS" "$FAIL" "$WARN" "$SCORE"
  first=1
  for r in "${RESULTS[@]}"; do IFS='|' read -r st id msg <<<"$r"
    [ $first = 1 ] || printf ','; first=0
    printf '{"status":"%s","id":"%s","msg":"%s"}' "$st" "$id" "$(printf '%s' "$msg" | sed 's/"/\\"/g')"
  done
  printf ']}\n'
else
  log ""
  log "${B}section $SECTION${N}  ${G}$PASS pass${N}  ${R}$FAIL fail${N}  ${Y}$WARN warn${N}"
  [ "$FAIL" -gt 0 ] \
    && log "${R}Not ready.${N} Fix the FAILs; warnings are judgement calls for the pull request." \
    || log "${G}Section clean.${N}"
fi

[ "$FAIL" -eq 0 ]
