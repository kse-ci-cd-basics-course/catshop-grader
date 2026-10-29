#!/usr/bin/env bash
#
# section: pipeline — test, build, publish, in one workflow, with the gate intact.
#
# Nothing here runs the student's pipeline; the grader cannot trigger somebody
# else's workflow. It reads the file, and the checks are properties the file
# either has or does not — chiefly whether publishing is REACHABLE when the
# tests are red, which is `needs:` and nothing else.

section_run() {
  sect "the workflow exists"
  local wfs wf report
  wfs=$(ls ../.github/workflows/*.yml ../.github/workflows/*.yaml 2>/dev/null)
  [ -n "$wfs" ] || { bad "pipeline:file" "no workflow under .github/workflows/"; return; }

  wf=$(grep -l "ghcr.io\|docker" $wfs 2>/dev/null | head -1)
  wf="${wf:-$(echo "$wfs" | head -1)}"
  ok "pipeline:file" "grading $(basename "$wf")"

  report=$(python3 "$(dirname "${BASH_SOURCE[0]}")/read_workflow.py" "$wf" 2>/tmp/wf.$$)
  if [ -z "$report" ]; then
    bad "pipeline:parses" "it does not parse as YAML"; head -3 /tmp/wf.$$ >&2; return
  fi
  ok "pipeline:parses" "it is valid YAML"

  sect "three stages"
  local tj bj pj
  tj=$(sed -n 's/^TESTS //p'  <<<"$report")
  bj=$(sed -n 's/^BUILDS //p' <<<"$report")
  pj=$(sed -n 's/^PUSHES //p' <<<"$report")

  [ -n "$tj" ] && ok "pipeline:test"    "a job runs pytest ($tj)" \
               || bad "pipeline:test"    "no job runs the test suite"
  [ -n "$bj" ] && ok "pipeline:build"   "a job builds the image ($bj)" \
               || bad "pipeline:build"   "no job builds an image"
  [ -n "$pj" ] && ok "pipeline:publish" "a job publishes it ($pj)" \
               || bad "pipeline:publish" "no job pushes the image anywhere"

  sect "the gate"
  if grep -q '^GATED yes' <<<"$report"; then
    ok "pipeline:gate" "publishing needs the tests, so a red suite cannot publish"
  else
    bad "pipeline:gate" "the publish job does not depend on the test job — a failing test still ships"
  fi

  sect "the image is named honestly"
  grep -q '^GHCR yes' <<<"$report" \
    && ok  "pipeline:registry" "it publishes to ghcr.io" \
    || bad "pipeline:registry" "no ghcr.io in the workflow"

  grep -q '^LATEST yes' <<<"$report" \
    && bad "pipeline:latest" "tagged 'latest' — a moving pointer, not a version" \
    || ok  "pipeline:latest" "no 'latest' tag"

  grep -q '^REVISION yes' <<<"$report" \
    && ok  "pipeline:revision" "org.opencontainers.image.revision is labelled" \
    || bad "pipeline:revision" "no org.opencontainers.image.revision label"

  rm -f /tmp/wf.$$
}
