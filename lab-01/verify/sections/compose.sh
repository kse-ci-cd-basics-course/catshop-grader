#!/usr/bin/env bash
# Section 3 — Compose, Postgres and a named volume. The container is disposable;
# the data is not. That claim is tested by destroying the stack and coming back.

section_run() {
  sect "the files"
  need_file "$COMPOSE"
  need_file .env.example

  check_compose_shape
  [ -f "$COMPOSE" ] || return

  # the shape the lesson turns on
  grep -qE '^[[:space:]]*volumes:' "$COMPOSE" \
    && ok  "compose:volumes" "volumes declared" \
    || bad "compose:volumes" "no volumes: — the data dies with the container"

  grep -q 'healthcheck:' "$COMPOSE" \
    && ok  "compose:healthcheck" "healthcheck present" \
    || bad "compose:healthcheck" "no healthcheck on the database"

  # depends_on alone waits for the container to start, not for Postgres to accept
  # connections. Without the gate the app must retry — and ours does.
  grep -q 'service_healthy' "$COMPOSE" \
    && ok   "compose:gate" "depends_on gated on service_healthy" \
    || warn "compose:gate" "no service_healthy gate — the app must then retry, and ours does"

  local dbports
  dbports="$(grep -nE '^[[:space:]]*-[[:space:]]*"?[0-9.]*:?[0-9]*:?5432' "$COMPOSE" || true)"
  if [ -z "$dbports" ]; then
    ok "compose:dbport" "the database port is not published"
  elif printf '%s\n' "$dbports" | grep -qv '127\.0\.0\.1'; then
    bad "compose:dbport" "the database port is published beyond loopback"
  else
    warn "compose:dbport" "database on loopback only — fine for debugging, say so in the pull request"
  fi

  run_stack || return

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

  sect "does the data survive down/up?"
  before="${v2:-0}"
  docker compose -f "$COMPOSE" down >/dev/null 2>&1
  docker compose -f "$COMPOSE" up -d >/dev/null 2>&1
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
