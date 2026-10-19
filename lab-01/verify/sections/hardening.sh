#!/usr/bin/env bash
# Section 2 — multi-stage and non-root: nothing the build needed may ship.

section_run() {
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
  uid="$(docker run --rm "$IMG" id -u 2>/dev/null | tr -dc '0-9')"
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
