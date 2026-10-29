#!/usr/bin/env bash
#
# section: published-image — the grader stops building and starts PULLING.
#
# This is the section a locally built image cannot pass. The student commits
# the reference their publish job emitted, and everything here is asked of the
# bytes in the registry: they exist, they run, they answer, and the label on
# them names a commit that is really in this repository.

REF_FILE=published.txt

section_run() {
  sect "the reference"
  need_file "$REF_FILE"
  [ -f "$REF_FILE" ] || return

  local ref digest repo sha
  ref=$(tr -d ' \t\r\n' < "$REF_FILE")
  [ -n "$ref" ] || { bad "image:ref" "$REF_FILE is empty"; return; }

  case "$ref" in
    *@sha256:*) ok  "image:bydigest" "pinned by digest" ;;
    *:*)        bad "image:bydigest" "that is a tag, not a digest — a tag can be moved after grading"; return ;;
    *)          bad "image:bydigest" "not an image reference: $ref"; return ;;
  esac

  case "$ref" in
    ghcr.io/*) ok "image:registry" "published to ghcr.io" ;;
    *)         warn "image:registry" "not ghcr.io — allowed, but the course publishes there" ;;
  esac

  sect "pull it"
  if ! docker pull -q "$ref" >/tmp/pull.$$ 2>&1; then
    bad "image:pull" "cannot pull it — is the package public?"; tail -5 /tmp/pull.$$ >&2; return
  fi
  ok "image:pull" "pulled from the registry"

  sect "it is yours, and it is this commit"
  sha=$(docker inspect --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$ref" 2>/dev/null)
  if [ -z "$sha" ] || [ "$sha" = "<no value>" ]; then
    bad "image:revision" "no org.opencontainers.image.revision label — nothing ties it to a commit"
  elif git cat-file -e "$sha" 2>/dev/null; then
    ok "image:revision" "built from ${sha:0:7}, which is in this repository"
  else
    bad "image:revision" "labelled $sha, which is not a commit in this repository"
  fi

  sect "run what was pulled"
  docker rm -f "$IMG" >/dev/null 2>&1 || true
  if ! docker run -d --name "$IMG" -p "${PORT}:8080" "$ref" >/dev/null 2>&1; then
    bad "image:start" "it does not start"; docker logs "$IMG" 2>&1 | tail -10 >&2; return
  fi
  ok "image:start" "the published image starts"

  if wait_up 60; then
    ok "image:health" "/health answers from the published image"
  else
    bad "image:health" "no answer on $BASE/health after 60s"
    docker logs "$IMG" 2>&1 | tail -10 >&2
  fi

  sect "it is the app, not an empty box"
  if curl -fsS --max-time 5 "$BASE/visits" | grep -q 'visits'; then
    ok "image:visits" "/visits answers with state"
  else
    bad "image:visits" "/visits does not answer — this is not the catshop app"
  fi
  rm -f /tmp/pull.$$
}
