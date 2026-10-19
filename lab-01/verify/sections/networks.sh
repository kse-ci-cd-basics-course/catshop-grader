#!/usr/bin/env bash
# Bonus — inbound publishing and outbound egress are different doors. Open one,
# close the other.

section_run() {
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
