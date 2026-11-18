#!/usr/bin/env bash
#
# verify.sh — grade ONE section of lab 2. Everything is in this file.
#
#   ./verify.sh --section tests --path lab-02
#   ./verify.sh --section pipeline --path lab-02 --json
#
#   tests             a suite that runs, passes, and tests the app   section 1
#   pipeline          test -> build -> publish, and the gate holds     section 2
#   published-image   pulled from the registry by digest, and run      section 3
#   cache             a cache that is keyed properly and measured      bonus
#
# Flags: --path DIR · --port N · --json · --keep · --bonus
# Exit 0 = nothing failed. A WARN is a judgement call for the pull request.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECTION=""; WORKDIR=""; JSON="${JSON:-0}"; KEEP="${KEEP:-0}"; BONUS=0
LIB="${LAB02_LIB:-0}"      # 1 = only define the functions, for tests/run.sh

if [ "$LIB" = 0 ]; then
while [ $# -gt 0 ]; do
  case "$1" in
    --section) SECTION="${2:?--section needs a value}"; shift 2 ;;
    --path)    WORKDIR="${2:?--path needs a value}";    shift 2 ;;
    --port)    PORT="${2:?--port needs a value}";       shift 2 ;;
    --json)    JSON=1; shift ;;
    --keep)    KEEP=1; shift ;;
    --bonus)   BONUS=1; shift ;;   # report, never fail: a bonus cannot cost marks
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done
case "$SECTION" in
  tests|pipeline|published-image|cache) : ;;
  "") echo "--section is required: tests | pipeline | published-image | cache" >&2; exit 2 ;;
  *)  echo "unknown section '$SECTION'" >&2; exit 2 ;;
esac

# One lab per folder, so the grader is pointed at a folder rather than the
# repository root. git still resolves from here, which the secret checks need.
if [ -n "$WORKDIR" ]; then
  cd "$WORKDIR" || { echo "no such path: $WORKDIR" >&2; exit 2; }
fi
fi

export JSON KEEP
# shellcheck source=../common/lib.sh
. "$HERE/../common/lib.sh"
# shellcheck source=../common/secrets.sh
. "$HERE/../common/secrets.sh"
[ "$LIB" = 0 ] && trap cleanup EXIT

# ── sections ─────────────────────────────────────────────────────────────────

#
# section: tests — a suite that runs, passes, and actually tests the application.
#
# The hard part of grading a test suite is that `assert True` passes. So this
# section asks three different questions: does it run, does it touch the app at
# all, and does it still pass when the app is broken on purpose.

section_tests() {
  sect "the suite is there"
  need_file requirements.txt
  [ -d tests ] && ok "tests:dir" "tests/ exists" || { bad "tests:dir" "no tests/ folder"; return; }

  local files n
  files=$(find tests -name 'test_*.py' | wc -l | tr -d ' ')
  [ "$files" -ge 1 ] && ok "tests:files" "$files test file(s)" \
                     || { bad "tests:files" "no test_*.py under tests/"; return; }

  grep -qiE '^pytest' requirements-dev.txt 2>/dev/null \
    && ok "tests:pytest" "pytest is a declared dependency" \
    || bad "tests:pytest" "pytest is not in requirements-dev.txt"

  sect "it runs, and it passes"
  python3 -m venv /tmp/venv.$$ >/dev/null 2>&1
  local PY=/tmp/venv.$$/bin/python
  if ! $PY -m pip install -q -r requirements.txt -r requirements-dev.txt >/tmp/pip.$$ 2>&1; then
    bad "tests:install" "dependencies do not install"; tail -10 /tmp/pip.$$ >&2; return
  fi
  ok "tests:install" "dependencies install"

  if ! $PY -m pytest tests -q >/tmp/pt.$$ 2>&1; then
    bad "tests:pass" "the suite does not pass"; tail -20 /tmp/pt.$$ >&2; return
  fi
  n=$(grep -oE '[0-9]+ passed' /tmp/pt.$$ | head -1 | grep -oE '[0-9]+')
  ok "tests:pass" "${n:-?} passed"
  [ "${n:-0}" -ge 4 ] && ok "tests:count" "$n tests" \
                      || warn "tests:count" "only ${n:-0} — four is the floor for a real suite"

  sect "it tests the application, not itself"
  grep -rqE '^(import|from) +app' tests/ \
    && ok "tests:imports" "the suite imports app" \
    || bad "tests:imports" "nothing under tests/ imports app — what is it testing?"

  # the mutation check: break the app and the suite must notice. This is the one
  # that cannot be satisfied by `assert True`.
  if [ -f app.py ]; then
    cp app.py /tmp/app.$$.bak
    # /health is the one endpoint every lab has, so break that
    sed -i.bak 's|return "ok\\n"|return "broken\\n", 500|' app.py 2>/dev/null
    if $PY -m pytest tests -q >/dev/null 2>&1; then
      bad "tests:catches" "the suite passes with /health returning 500 — it is not testing the app"
    else
      ok "tests:catches" "breaking /health makes the suite fail"
    fi
    mv /tmp/app.$$.bak app.py; rm -f app.py.bak
  else
    warn "tests:catches" "no app.py at the lab root, so the mutation check was skipped"
  fi
  rm -rf /tmp/venv.$$ /tmp/pip.$$ /tmp/pt.$$
}

#
# section: pipeline — test, build, publish, in one workflow, with the gate intact.
#
# Nothing here runs the student's pipeline; the grader cannot trigger somebody
# else's workflow. It reads the file, and the checks are properties the file
# either has or does not — chiefly whether publishing is REACHABLE when the
# tests are red, which is `needs:` and nothing else.

section_pipeline() {
  sect "the workflow exists"
  local wfs wf f n report best best_report
  wfs=$(ls ../.github/workflows/*.yml ../.github/workflows/*.yaml 2>/dev/null)
  [ -n "$wfs" ] || { bad "pipeline:file" "no workflow under .github/workflows/"; return; }

  # No PyYAML = every file "fails to parse", which blames the student.
  if [ -z "${PYYAML:-}" ]; then
    bad "pipeline:grader" "the grader has no PyYAML on this runner, so it cannot read any workflow — this is the course's bug, not yours; please report it"
    return
  fi

  # Grade the workflow that comes CLOSEST to what this section asks for, not the
  # first file that happens to say "docker": an earlier lab's workflow is still
  # in the repository, still mentions docker, and used to win on `head -1`.
  # Reported by Viktoriia Semenko, 2026-11-15.
  # The course's own grading workflows are never candidates.
  best=-1; n=0
  for f in $wfs; do
    grep -q 'catshop-grader' "$f" && continue
    n=$((n + 1))
    report=$("$PYYAML" "$HERE/read_workflow.py" "$f" 2>/dev/null) || continue
    [ -n "$report" ] || continue
    local score=0
    [ -n "$(sed -n 's/^TESTS //p'  <<<"$report")" ] && score=$((score + 1))
    [ -n "$(sed -n 's/^BUILDS //p' <<<"$report")" ] && score=$((score + 1))
    [ -n "$(sed -n 's/^PUSHES //p' <<<"$report")" ] && score=$((score + 1))
    grep -q '^GATED yes' <<<"$report" && score=$((score + 2))
    grep -q '^GHCR yes'  <<<"$report" && score=$((score + 1))
    if [ "$score" -gt "$best" ]; then best=$score; wf="$f"; best_report="$report"; fi
  done

  if [ "$n" -eq 0 ]; then
    bad "pipeline:file" "the only workflows here are the course's grading ones — where is yours?"
    return
  fi
  if [ "$best" -lt 0 ]; then
    wf=$(for f in $wfs; do grep -q 'catshop-grader' "$f" || { echo "$f"; break; }; done)
    ok  "pipeline:file" "grading $(basename "$wf")"
    bad "pipeline:parses" "it does not parse as YAML"
    "$PYYAML" "$HERE/read_workflow.py" "$wf" 2>&1 >/dev/null | head -3 >&2
    return
  fi

  report="$best_report"
  if [ "$n" -gt 1 ]; then
    ok "pipeline:file" "grading $(basename "$wf") — the closest of $n workflows"
  else
    ok "pipeline:file" "grading $(basename "$wf")"
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

#
# section: published-image — the grader stops building and starts PULLING.
#
# This is the section a locally built image cannot pass. The student commits
# the reference their publish job emitted, and everything here is asked of the
# bytes in the registry: they exist, they run, they answer, and the label on
# them names a commit that is really in this repository.

REF_FILE=published.txt

section_published_image() {
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

#
# section: cache — bonus. Keyed on something that changes, measured, and proved
# to exist via the Actions cache API.

section_cache() {
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

  cache_exists_in_the_repository

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

# A `cache:` block that saved nothing is still perfect YAML, so ask the API:
# list the entries, take the newest, fetch it again by its own key and ref, and
# require the same id back. Needs `actions: read`; without it, WARN not FAIL.
cache_exists_in_the_repository() {
  sect "the cache exists, not just the YAML"

  local token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  local repo="${GITHUB_REPOSITORY:-}"
  if [ -z "$token" ] || [ -z "$repo" ]; then
    warn "cache:api" "no token or repository in the environment — run this in Actions to grade it"
    return
  fi

  local api="https://api.github.com/repos/$repo/actions/caches"
  local body code
  body=$(curl -sS -w '\n%{http_code}' -m 20 \
          -H "Authorization: Bearer $token" \
          -H "Accept: application/vnd.github+json" \
          -H "X-GitHub-Api-Version: 2022-11-28" \
          "$api?per_page=100" 2>/dev/null)
  code=$(tail -1 <<<"$body"); body=$(sed '$d' <<<"$body")

  case "$code" in
    200) ok "cache:api" "the cache API answered" ;;
    403) warn "cache:api" "403 — the grading job needs permissions: actions: read"; return ;;
    *)   warn "cache:api" "the cache API answered $code"; return ;;
  esac

  local line id key ref size count
  line=$(python3 - "$body" <<'PY' 2>/dev/null
import json, sys
try:
    entries = json.loads(sys.argv[1]).get("actions_caches", [])
except Exception:
    entries = []
if entries:
    e = sorted(entries, key=lambda c: c.get("created_at", ""))[-1]
    print("\t".join(str(e.get(k, "")) for k in ("id", "key", "ref", "size_in_bytes")))
print(f"COUNT\t{len(entries)}")
PY
)
  count=$(sed -n 's/^COUNT\t//p' <<<"$line")
  IFS=$'\t' read -r id key ref size <<<"$(grep -v '^COUNT' <<<"$line" | head -1)"

  if [ "${count:-0}" -eq 0 ]; then
    bad "cache:entry" "the repository has no cache entries — the save step never ran, or the job failed before it"
    return
  fi
  ok "cache:entry" "${count} cache entr$([ "$count" = 1 ] && echo y || echo ies) in this repository"

  [ -n "$key" ] && ok "cache:named" "newest is '$key' on $ref" \
                || { bad "cache:named" "an entry with no key"; return; }

  local again aid acode
  again=$(curl -sS -w '\n%{http_code}' -m 20 \
           -H "Authorization: Bearer $token" \
           -H "Accept: application/vnd.github+json" \
           -H "X-GitHub-Api-Version: 2022-11-28" \
           --get --data-urlencode "key=$key" --data-urlencode "ref=$ref" \
           "$api" 2>/dev/null)
  acode=$(tail -1 <<<"$again"); again=$(sed '$d' <<<"$again")
  if [ "$acode" = 200 ]; then
    aid=$(python3 - "$again" "$id" <<'PY' 2>/dev/null
import json, sys
try:
    entries = json.loads(sys.argv[1]).get("actions_caches", [])
except Exception:
    entries = []
print(next((str(e["id"]) for e in entries if str(e.get("id")) == sys.argv[2]), ""))
PY
)
    [ -n "$aid" ] && ok "cache:byid" "fetched again by key and ref — same entry, id $aid" \
                  || bad "cache:byid" "the entry does not come back when asked for by its own key and ref"
  else
    warn "cache:byid" "the filtered query answered $acode"
  fi

  if [ "${size:-0}" -gt 1024 ]; then
    ok "cache:size" "$(( size / 1024 )) KB stored"
  else
    bad "cache:size" "the entry holds ${size:-0} bytes — that is an empty cache"
  fi
}

# ── run it ───────────────────────────────────────────────────────────────────
[ "$LIB" = 1 ] && return 0

log "${B}catshop lab 2 · section: $SECTION${N}"
"section_$(printf '%s' "$SECTION" | tr - _)"
check_secrets                 # every section, always
rm -f /tmp/b.$$ /tmp/cb.$$ /tmp/cu.$$

emit_report "$SECTION"

# A bonus section reports and exits clean: it can only ever add marks, so a red
# one must not show up as a failed check.
[ "$BONUS" = 1 ] && exit 0
[ "$FAIL" -eq 0 ]
