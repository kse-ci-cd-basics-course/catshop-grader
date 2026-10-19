#!/usr/bin/env bash
# Section 3 — Compose, Postgres and a named volume. The container is disposable;
# the data is not. That claim is tested by destroying the stack and coming back.

section_run() {
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
