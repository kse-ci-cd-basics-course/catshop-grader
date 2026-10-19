#!/usr/bin/env bash
# Bonus — the partner API we do not own, replaced by a stub that can fail on demand.

section_run() {
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
