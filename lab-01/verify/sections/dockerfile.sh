#!/usr/bin/env bash
# Section 1 — a Dockerfile that runs. No Compose: this section is about the image.

section_run() {
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
