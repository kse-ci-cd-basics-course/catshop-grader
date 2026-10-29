#!/usr/bin/env bash
#
# section: cache — bonus. Keyed on something that changes, and MEASURED.
#
# Lab 3 is marked on caching properly. Here it can only add, so the bar is: a
# cache that is keyed on the lockfile rather than on nothing, and two numbers
# that show it did something.

section_run() {
  sect "a cache is configured"
  local wfs text
  wfs=$(ls ../.github/workflows/*.yml ../.github/workflows/*.yaml 2>/dev/null)
  [ -n "$wfs" ] || { bad "cache:file" "no workflow to read"; return; }
  text=$(cat $wfs)

  if grep -q 'actions/cache@\|cache: *pip\|cache: *npm\|cache-from:' <<<"$text"; then
    ok "cache:present" "a cache is configured"
  else
    bad "cache:present" "no actions/cache, no setup-* cache: key, no buildx cache-from"
    return
  fi

  sect "it is keyed on something that changes"
  if grep -q 'hashFiles(' <<<"$text"; then
    ok "cache:key" "the key contains hashFiles()"
  elif grep -qE 'cache: *(pip|npm|yarn|maven|gradle)' <<<"$text"; then
    ok "cache:key" "a setup-* action, which keys on the lockfile for you"
  else
    bad "cache:key" "a key with no hashFiles() never changes, so the cache is never refreshed"
  fi

  if grep -q 'cache-to:.*mode=max' <<<"$text"; then
    ok "cache:mode" "mode=max — intermediate stages are cached too"
  elif grep -q 'cache-from:' <<<"$text"; then
    warn "cache:mode" "layer cache without mode=max caches only the final stage"
  fi

  sect "and it was measured"
  need_file CACHE.md
  [ -f CACHE.md ] || return
  local times
  times=$(grep -coE '[0-9]+ *(m|min|s|sec)' CACHE.md)
  if [ "$times" -ge 2 ]; then
    ok "cache:measured" "two timings written down"
  else
    bad "cache:measured" "CACHE.md needs a cold run and a warm run, with both times"
  fi
}
