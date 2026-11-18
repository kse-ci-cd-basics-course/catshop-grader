#!/usr/bin/env bash
#
# verify.sh — grade ONE section of lab 3. Everything is in this file.
#
#   ./verify.sh --section reuse --path lab-03
#   ./verify.sh --section cache --path lab-03 --json
#
#   reuse        one definition of test-and-build, called twice   required
#   cache        both stores, proved, and the minutes saved       required
#   qa           the stage that drives the published digest       bonus
#   aqa          scenarios of your own, beyond the given five     bonus
#   concurrency  the group, and a run that was really cancelled   bonus
#
# Four checks ask the Actions API rather than the YAML: a reusable call that
# really ran, caches fetched back by key and id, the pasted run timings against
# the runs' real durations, and a run that was really cancelled. They need
# `actions: read`; without it they WARN.
#
# Flags: --path DIR · --port N · --json · --keep · --bonus
# Exit 0 = nothing failed. A WARN is a judgement call for the pull request.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECTION=""; WORKDIR=""; JSON="${JSON:-0}"; KEEP="${KEEP:-0}"; BONUS=0
LIB="${LAB03_LIB:-0}"          # 1 = only define the functions, for tests/run.sh

if [ "$LIB" = 0 ]; then
while [ $# -gt 0 ]; do
  case "$1" in
    --section) SECTION="${2:?--section needs a value}"; shift 2 ;;
    --path)    WORKDIR="${2:?--path needs a value}";    shift 2 ;;
    --port)    PORT="${2:?--port needs a value}";       shift 2 ;;
    --json)    JSON=1; shift ;;
    --keep)    KEEP=1; shift ;;
    --bonus)   BONUS=1; shift ;;   # report, never fail: a bonus cannot cost marks
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done
case "$SECTION" in
  reuse|cache|qa|aqa|concurrency) : ;;
  "") echo "--section is required: reuse | cache | qa | aqa | concurrency" >&2; exit 2 ;;
  *)  echo "unknown section '$SECTION'" >&2; exit 2 ;;
esac

# The lab folder is the working directory; the workflows are one level up, at
# the repository root, which is the only place GitHub reads them from.
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

WF=../.github/workflows
ACT=../.github/actions
WFR=""            # the workflow report, read once and shared by the sections

read_workflows() {
  [ -n "$WFR" ] && return 0
  [ -d "$WF" ] || return 1
  # No PyYAML = every section would blame the student's workflow. Say it once.
  if [ -z "${PYYAML:-}" ]; then
    [ "${YAMLSAID:-0}" = 1 ] || bad "grader:yaml" "the grader has no PyYAML on this runner, so it cannot read any workflow — this is the course's bug, not yours; please report it"
    YAMLSAID=1
    return 1
  fi
  WFR=$("$PYYAML" "$HERE/read_workflows.py" "$WF" "$ACT" 2>/dev/null)
  [ -n "$WFR" ]
}

# ── the Actions API, for the four checks YAML cannot answer ──────────────────
API_CODE_FILE="${TMPDIR:-/tmp}/apicode.$$"

api_ready() {
  TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  REPO="${GITHUB_REPOSITORY:-}"
  API="https://api.github.com/repos/$REPO"
  [ -n "$TOKEN" ] && [ -n "$REPO" ]
}

gh_api() {
  local out
  out=$(curl -sS -w '\n%{http_code}' -m 25 \
        -H "Authorization: Bearer $TOKEN" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "$@" 2>/dev/null)
  printf '%s\n' "$(tail -1 <<<"$out")" > "$API_CODE_FILE"
  sed '$d' <<<"$out"
}

api_code() { cat "$API_CODE_FILE" 2>/dev/null; }

jq_py() {   # jq_py <json> <python expression over `d`>
  python3 - "$1" "$2" <<'PYEOF' 2>/dev/null
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    d = {}
print(eval(sys.argv[2], {"d": d, "sorted": sorted, "len": len, "next": next, "str": str, "set": set}))
PYEOF
}


# ── sections ─────────────────────────────────────────────────────────────────

#
# section: reuse — one definition, called twice.
#
# Nothing here runs the student's pipeline; the grader cannot trigger somebody
# else's workflow. It reads every workflow in the repository, resolves the
# reusable calls between them, and asks whether the pipeline has ONE definition
# of testing and building — plus one API check, because a workflow file can
# describe a reusable call that never happened.


section_reuse() {
  sect "the workflows, read together"
  [ -d "$WF" ] || { bad "reuse:file" "no .github/workflows/ at the repository root"; return; }

  if ! read_workflows; then
    bad "reuse:parses" "the workflows do not parse, or there is no .github/workflows/"; return
  fi
  if grep -q '^UNPARSEABLE' <<<"$WFR"; then
    bad "reuse:parses" "$(grep '^UNPARSEABLE' <<<"$WFR" | head -1 | cut -d' ' -f2) is not valid YAML"; return
  fi
  ok "reuse:parses" "$(sed -n 's/^WORKFLOWS //p' <<<"$WFR") workflow file(s), all valid YAML"

  sect "a workflow calls a workflow"
  local calls
  calls=$(grep -c '^CALLER ' <<<"$WFR")
  if [ "$calls" -ge 1 ]; then
    ok "reuse:caller" "$(grep '^CALLER ' <<<"$WFR" | sed 's/^CALLER //' | tr '\n' ';' | sed 's/;$//')"
  else
    bad "reuse:caller" "no job uses: another workflow — nothing is reused"; return
  fi

  grep -q '^CALLED ' <<<"$WFR" \
    && ok  "reuse:called" "$(grep -c '^CALLED ' <<<"$WFR") workflow(s) declare on: workflow_call" \
    || bad "reuse:called" "the file being called does not declare on: workflow_call"

  sect "it takes arguments, and gives an answer back"
  local n typed untyped
  read -r n _ typed _ untyped < <(sed -n 's/^INPUTS //p' <<<"$WFR")
  if [ "${n:-0}" -eq 0 ]; then
    bad "reuse:typed" "the called workflow declares no inputs — it is a copy with extra steps"
  elif [ "${untyped:-0}" -gt 0 ]; then
    bad "reuse:typed" "$untyped input(s) with no type: — workflow_call inputs are typed"
  else
    ok "reuse:typed" "$typed typed input(s)"
  fi

  grep -q '^INPUTUSED yes' <<<"$WFR" \
    && ok  "reuse:inputused" "the called workflow reads inputs.*" \
    || bad "reuse:inputused" "nothing inside the called workflow reads an input"

  if grep -q '^WFOUTPUTS -' <<<"$WFR"; then
    bad "reuse:outputs" "the called workflow declares no outputs — the digest cannot come back"
  elif grep -q '^OUTPUTCONSUMED yes' <<<"$WFR"; then
    ok "reuse:outputs" "an output is declared and the caller reads needs.<job>.outputs"
  else
    bad "reuse:outputs" "outputs are declared but the caller never reads one"
  fi

  sect "the QA suite is the second one"
  local qa_in_called=no
  while read -r _ site; do
    local f="${site%%:*}"
    grep -q "^CALLED $f\$" <<<"$WFR" && qa_in_called=yes
  done < <(grep '^QA ' <<<"$WFR")

  if [ "$qa_in_called" = yes ]; then
    ok "reuse:qa-called" "the QA suite runs inside a reusable workflow"
  else
    bad "reuse:qa-called" "the QA suite is not a reusable workflow — lab 5 calls this same file against three environments"
  fi

  grep -q '^QAINPUT yes' <<<"$WFR" \
    && ok  "reuse:qa-input" "the QA call is passed the image rather than knowing it" \
    || bad "reuse:qa-input" "the QA call hardcodes what it tests — pass it in with:"

  sect "steps compose into a job"
  local comp
  comp=$(sed -n 's/^COMPOSITE //p' <<<"$WFR")
  if [ "$comp" = "-" ]; then
    bad "reuse:composite" "no composite action under .github/actions/"
  else
    ok "reuse:composite" "${comp#../}"
    grep -q '^COMPOSITEINREUSE yes' <<<"$WFR" \
      && ok  "reuse:composite-inside" "the reusable workflow is what calls it" \
      || warn "reuse:composite-inside" "the composite action is only called from the caller — inside the reusable workflow is the normal arrangement"
  fi

  sect "one definition, not four copies"
  local tf bf
  tf=$(sed -n 's/^TESTFILES //p' <<<"$WFR"); bf=$(sed -n 's/^BUILDFILES //p' <<<"$WFR")
  [ "${tf:-0}" -le 1 ] && ok "reuse:nocopy-test" "the unit suite is invoked in one file" \
                       || bad "reuse:nocopy-test" "pytest is invoked in $tf different workflow files"
  [ "${bf:-0}" -le 1 ] && ok "reuse:nocopy-build" "the image is built in one file" \
                       || bad "reuse:nocopy-build" "the image is built in $bf different workflow files"

  sect "what you call, and at which version"
  if grep -q '^UNPINNED ' <<<"$WFR"; then
    bad "reuse:pinned" "$(grep '^UNPINNED ' <<<"$WFR" | head -1 | sed 's/^UNPINNED //')"
  else
    ok "reuse:pinned" "every third-party uses: is at a tag or a sha"
  fi

  grep -q '^SECRETS yes' <<<"$WFR" \
    && ok   "reuse:secrets" "secrets are declared or inherited, not passed as inputs" \
    || warn "reuse:secrets" "nothing is passed as a secret — fine if nothing needs one, say so in the pull request"

  it_really_ran
  rm -f /tmp/rw.$$
}

# A reusable call has a signature from outside: the caller's run shows its jobs
# as "<calling job> / <called job>". No YAML can fake that, and no local run can
# produce it. Needs actions: read; without it, WARN.
it_really_ran() {
  sect "and it really ran"
  if ! api_ready; then
    warn "reuse:ran" "no token or repository — run this in Actions to grade it"; return
  fi

  local branch runs ids body found=""
  branch="${GITHUB_HEAD_REF:-${GITHUB_REF_NAME:-}}"
  runs=$(gh_api --get --data-urlencode "branch=$branch" --data-urlencode "per_page=20" \
                "$API/actions/runs")
  case "$(api_code)" in
    200) : ;;
    403) warn "reuse:ran" "403 — the grading job needs permissions: actions: read"; return ;;
    *)   warn "reuse:ran" "the runs API answered $(api_code)"; return ;;
  esac

  # the grader's own run is a run too, so look at several and skip this workflow
  ids=$(jq_py "$runs" "' '.join(str(r['id']) for r in d.get('workflow_runs',[]) if r.get('name') != '${GITHUB_WORKFLOW:-}')" )
  ids=$(tr ' ' '\n' <<<"$ids" | head -8 | tr '\n' ' ')
  if [ -z "${ids// /}" ]; then
    bad "reuse:ran" "no run of your own pipeline on '$branch' — push it before it can be graded"; return
  fi

  local id
  for id in $ids; do
    body=$(gh_api "$API/actions/runs/$id/jobs?per_page=100")
    [ "$(api_code)" = 200 ] || continue
    found=$(jq_py "$body" "next((j['name'] for j in d.get('jobs',[]) if ' / ' in j.get('name','')), '')")
    [ -n "$found" ] && break
  done

  if [ -n "$found" ]; then
    ok "reuse:ran" "a run shows the job '$found' — that slash is a reusable call"
  else
    bad "reuse:ran" "no run on '$branch' shows a '<job> / <job>' name, so no reusable workflow has actually run"
  fi
}

#
# section: cache — both stores, and the minutes.
#
# Lab 2 rehearsed this as a bonus. Here it is required, and it is marked on the
# saving rather than on the YAML: the entries have to exist in the repository's
# cache, and the two run URLs in CACHE.md have to be real runs whose real
# durations show the speedup that was written down.


section_cache() {
  sect "both caches are configured"
  local wfs text
  wfs=$(ls $WF/*.yml $WF/*.yaml 2>/dev/null)
  [ -n "$wfs" ] || { bad "cache:file" "no workflow under .github/workflows/"; return; }
  text=$(cat $wfs)

  if grep -qE 'actions/cache@|cache: *(pip|npm|yarn|poetry|maven|gradle)' <<<"$text"; then
    ok "cache:deps" "a dependency cache is configured"
  else
    bad "cache:deps" "no actions/cache and no setup-* cache: key — the packages download on every run"
  fi

  if grep -q 'hashFiles(' <<<"$text"; then
    ok "cache:key" "the key contains hashFiles()"
  elif grep -qE 'cache: *(pip|npm|yarn|poetry|maven|gradle)' <<<"$text"; then
    ok "cache:key" "a setup-* action, which keys on the lockfile for you"
  else
    bad "cache:key" "a key with no hashFiles() never changes, so the cache is never refreshed"
  fi

  if grep -q 'restore-keys' <<<"$text"; then
    ok "cache:prefix" "restore-keys gives a prefix fallback, so a changed lockfile still starts warm"
  elif grep -qE 'cache: *(pip|npm|yarn|poetry|maven|gradle)' <<<"$text"; then
    warn "cache:prefix" "setup-* manages its own fallback; write your own key once to see the prefix work"
  else
    bad "cache:prefix" "no restore-keys — one changed dependency throws the whole cache away"
  fi

  if grep -q 'cache-from:' <<<"$text" && grep -q 'cache-to:' <<<"$text"; then
    ok "cache:layers" "the layer cache is configured as well as the dependency cache"
  else
    bad "cache:layers" "no cache-from/cache-to — the docker build rebuilds every layer every run"
  fi

  grep -q 'mode=max' <<<"$text" \
    && ok  "cache:mode" "mode=max — the intermediate stages are cached too, not only the last one" \
    || bad "cache:mode" "cache-to without mode=max caches only the final stage"

  local builds
  builds=$(grep -cE 'docker/build-push-action|docker buildx build' <<<"$text")
  if [ "${builds:-0}" -ge 2 ] && ! grep -q 'scope=' <<<"$text"; then
    warn "cache:scope" "$builds builds and no scope= — two builds sharing one scope evict each other"
  fi

  sect "the Dockerfile is ordered for it"
  if [ -f Dockerfile ]; then
    local req app
    req=$(grep -n -m1 -E '^[[:space:]]*COPY .*requirements' Dockerfile | cut -d: -f1)
    app=$(grep -n -m1 -E '^[[:space:]]*COPY \.|^[[:space:]]*COPY app' Dockerfile | cut -d: -f1)
    if [ -n "$req" ] && [ -n "$app" ] && [ "$req" -lt "$app" ]; then
      ok "cache:order" "requirements are copied and installed before the source"
    elif [ -n "$req" ] && [ -n "$app" ]; then
      bad "cache:order" "the source is copied before the requirements, so every edit invalidates the install"
    elif [ -z "$req" ] && grep -q 'pip install' Dockerfile; then
      bad "cache:order" "the requirements are never copied on their own — with COPY . . the install layer dies on every source edit"
    else
      warn "cache:order" "could not read the COPY order out of the Dockerfile"
    fi
  else
    warn "cache:order" "no Dockerfile in this folder"
  fi

  caches_exist
  measured
}

# A `cache:` block that saved nothing is still perfect YAML, so ask the API:
# list the entries, take the newest, fetch it again by its own key and ref, and
# require the same id back.
caches_exist() {
  sect "the caches exist, not just the YAML"
  if ! api_ready; then
    warn "cache:api" "no token or repository — run this in Actions to grade it"; return
  fi

  local body count id key ref size keys
  body=$(gh_api --get --data-urlencode "per_page=100" "$API/actions/caches")
  case "$(api_code)" in
    200) ok "cache:api" "the cache API answered" ;;
    403) warn "cache:api" "403 — the grading job needs permissions: actions: read"; return ;;
    *)   warn "cache:api" "the cache API answered $(api_code)"; return ;;
  esac

  count=$(jq_py "$body" "len(d.get('actions_caches',[]))")
  if [ "${count:-0}" -eq 0 ]; then
    bad "cache:entry" "this repository holds no cache entries — the save step never ran, or the job died before it"
    return
  fi
  ok "cache:entry" "$count cache entr$([ "$count" = 1 ] && echo y || echo ies)"

  id=$(jq_py  "$body" "sorted(d['actions_caches'], key=lambda c: c.get('created_at',''))[-1]['id']")
  key=$(jq_py "$body" "sorted(d['actions_caches'], key=lambda c: c.get('created_at',''))[-1].get('key','')")
  ref=$(jq_py "$body" "sorted(d['actions_caches'], key=lambda c: c.get('created_at',''))[-1].get('ref','')")
  size=$(jq_py "$body" "sorted(d['actions_caches'], key=lambda c: c.get('created_at',''))[-1].get('size_in_bytes',0)")
  [ -n "$key" ] && ok "cache:named" "newest is '$key' on $ref" \
                || { bad "cache:named" "an entry with no key"; return; }

  local again aid
  again=$(gh_api --get --data-urlencode "key=$key" --data-urlencode "ref=$ref" "$API/actions/caches")
  if [ "$(api_code)" = 200 ]; then
    aid=$(jq_py "$again" "next((str(e['id']) for e in d.get('actions_caches',[]) if str(e.get('id'))=='$id'), '')")
    [ -n "$aid" ] && ok  "cache:byid" "fetched again by its own key and ref — same entry, id $aid" \
                  || bad "cache:byid" "the entry does not come back when asked for by its own key and ref"
  else
    warn "cache:byid" "the filtered query answered $(api_code)"
  fi

  if [ "${size:-0}" -gt 1024 ]; then
    ok "cache:size" "$(( size / 1024 )) KB stored"
  else
    bad "cache:size" "the newest entry holds ${size:-0} bytes — that is an empty cache"
  fi

  # two stores, not one: buildkit writes its own entries, with keys nobody typed
  keys=$(jq_py "$body" "len(set(e.get('key','').split('-')[0] for e in d.get('actions_caches',[])))")
  if [ "${keys:-1}" -ge 2 ]; then
    ok "cache:both" "$keys different key families — the dependency cache and the layer cache are separate stores"
  else
    warn "cache:both" "every entry shares one key family; the layer cache may not have saved anything yet"
  fi
}

# The numbers. Two timings, a stated delta, and two run URLs the API can confirm.
measured() {
  sect "and it was measured"
  need_file CACHE.md
  [ -f CACHE.md ] || return

  local times
  times=$(grep -coE '[0-9]+([.,][0-9]+)? *(m|min|mins|minutes|s|sec|secs|seconds)\b' CACHE.md)
  [ "${times:-0}" -ge 2 ] && ok "cache:measured" "a cold time and a warm time are written down" \
                          || bad "cache:measured" "CACHE.md needs both runs timed — cold and warm"

  grep -qiE 'saved|faster|delta|difference|-[0-9]' CACHE.md \
    && ok  "cache:minutes" "the saving is stated, not left to be worked out" \
    || bad "cache:minutes" "say what the cache saved — the delta is the point of the section"

  local ids
  ids=$(grep -oE 'actions/runs/[0-9]+' CACHE.md | grep -oE '[0-9]+' | sort -u)
  if [ -z "$ids" ]; then
    bad "cache:evidence" "no run URLs in CACHE.md — paste the cold run and the warm run"
    return
  fi
  ok "cache:evidence" "$(wc -w <<<"$ids" | tr -d ' ') run URL(s) pasted"

  api_ready || { warn "cache:runs" "no token — the pasted runs could not be checked"; return; }

  local id secs durations=()
  for id in $ids; do
    local run
    run=$(gh_api "$API/actions/runs/$id")
    if [ "$(api_code)" != 200 ]; then
      warn "cache:runs" "run $id answered $(api_code) — is it a run of this repository?"; continue
    fi
    secs=$(python3 - "$run" <<'PY' 2>/dev/null
import json, sys, datetime
d = json.loads(sys.argv[1])
f = "%Y-%m-%dT%H:%M:%SZ"
try:
    a = datetime.datetime.strptime(d["run_started_at"], f)
    b = datetime.datetime.strptime(d["updated_at"], f)
    print(int((b - a).total_seconds()))
except Exception:
    print("")
PY
)
    [ -n "$secs" ] && durations+=("$secs")
  done

  if [ "${#durations[@]}" -lt 2 ]; then
    warn "cache:runs" "fewer than two of the pasted runs could be read back"
    return
  fi

  local cold warm
  cold=$(printf '%s\n' "${durations[@]}" | sort -n | tail -1)
  warm=$(printf '%s\n' "${durations[@]}" | sort -n | head -1)
  if [ "$cold" -gt 0 ] && [ $(( (cold - warm) * 100 / cold )) -ge 20 ]; then
    ok "cache:runs" "the runs themselves say ${cold}s cold against ${warm}s warm"
  else
    bad "cache:runs" "the pasted runs took ${cold}s and ${warm}s — that is not a cache working, whatever CACHE.md says"
  fi
}

#
# section: qa — bonus. The stage that drives what you published.
#
# The suite and the stack are given, so nothing here grades scenarios. What it
# grades is the JOB: does the digest reach it, is the stack what runs, does
# anything depend on the result. Then it does the stage itself — pull the digest
# out of published.txt, bring the given stack up against it, run the suite,
# tear it down — because a job that looks right and an image that answers are
# two different claims.

REF_FILE=published.txt
QA_COMPOSE=qa/compose.qa.yaml

section_qa() {
  sect "the suite and the stack you were given"
  if [ ! -d qa ]; then
    bad "qa:suite" "no qa/ folder — it came with the lab, and nothing here works without it"; return
  fi
  local files
  files=$(find qa -name 'test_*.py' | wc -l | tr -d ' ')
  [ "$files" -ge 1 ] && ok "qa:suite" "$files QA file(s) under qa/" \
                     || { bad "qa:suite" "no test_*.py under qa/"; return; }

  need_file "$QA_COMPOSE"
  if [ -f "$QA_COMPOSE" ]; then
    if grep -qE '^[[:space:]]*build:' "$QA_COMPOSE"; then
      bad "qa:nobuild" "the stack has a build: — then it is not testing what you published"
    else
      ok "qa:nobuild" "the app service pulls an image; nothing in the stack builds one"
    fi
  fi

  if grep -rqE '^(import|from) +app|test_client\(' qa/ 2>/dev/null; then
    bad "qa:blackbox" "something in qa/ imports the app or uses Flask's test client — that is a unit test, not AQA"
  else
    ok "qa:blackbox" "nothing in qa/ imports the app — it drives it from outside"
  fi

  sect "where the stage sits in the pipeline"
  read_workflows || true
  if [ -z "$WFR" ]; then
    bad "qa:job" "the workflows do not parse, so the stage cannot be read"
  elif ! grep -q '^QA ' <<<"$WFR"; then
    bad "qa:job" "no job runs the QA suite — this bonus is that job"
  else
    ok "qa:job" "$(grep -c '^QA ' <<<"$WFR") job(s) run the suite"

    local qa_text
    qa_text=$(qa_job_text "$WFR")
    if grep -q 'docker compose' <<<"$qa_text"; then
      ok "qa:stack" "the job brings the given stack up itself"
    else
      bad "qa:stack" "the job never runs docker compose — the suite needs the stack, not just the image"
    fi

    if grep -qE 'pytest' <<<"$qa_text"; then
      ok "qa:inline" "the pull, the stack and the suite are steps in the job, where they can be read"
    else
      warn "qa:inline" "the suite is invoked indirectly — a stage nobody can read in the workflow file is a stage nobody debugs at 02:00"
    fi

    if grep -qE 'down|always\(\)' <<<"$qa_text"; then
      ok "qa:teardown" "the stack comes down afterwards"
    else
      warn "qa:teardown" "nothing tears the stack down — on a self-hosted runner that is the next job's problem"
    fi

    grep -q '^QADIGEST yes' <<<"$WFR" \
      && ok  "qa:digest" "the job is given a digest" \
      || bad "qa:digest" "the job is not given a digest — a tag can move between the build and this run"

    grep -q '^QALATEST yes' <<<"$WFR" \
      && bad "qa:latest" "':latest' appears on the QA path — the one reference that can change under you" \
      || ok  "qa:latest" "no ':latest' on the QA path"

    grep -q '^GATE yes' <<<"$WFR" \
      && ok  "qa:gate" "shipping depends on the QA job — a red suite cannot promote" \
      || bad "qa:gate" "nothing depends on the QA job, so a red suite changes nothing about what ships"
  fi

  drive_the_published_image
}

# the qa node's own steps, plus the file it calls if it is a reusable call
qa_job_text() {
  local report="$1" site f j
  for site in $(grep '^QA ' <<<"$report" | sed 's/^QA //'); do
    f="${site%%:*}"; j="${site##*:}"
    "${PYYAML:-python3}" - "$WF/$f" "$j" <<'PY' 2>/dev/null
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1], errors="replace").read()) or {}
print(yaml.dump((doc.get("jobs") or {}).get(sys.argv[2], {})))
PY
    cat "$WF/$f" 2>/dev/null
  done
}

# The stage, for real: the bytes come from the registry and the stack is the one
# in the repository. Nothing is graded on how fast it is, only that it answers.
drive_the_published_image() {
  sect "the stage, run here"
  need_file "$REF_FILE"
  [ -f "$REF_FILE" ] || return
  [ -f "$QA_COMPOSE" ] || { warn "qa:runs" "no $QA_COMPOSE to bring up"; return; }

  local ref
  ref=$(tr -d ' \t\r\n' < "$REF_FILE")
  case "$ref" in
    *@sha256:*) ok  "qa:ref" "published.txt is pinned by digest" ;;
    "")         bad "qa:ref" "$REF_FILE is empty"; return ;;
    *)          bad "qa:ref" "that is not a digest reference: $ref"; return ;;
  esac

  if ! docker pull -q "$ref" >/tmp/pull.$$ 2>&1; then
    bad "qa:pull" "cannot pull it — is the package public?"; tail -5 /tmp/pull.$$ >&2; return
  fi
  ok "qa:pull" "pulled from the registry"

  python3 -m venv /tmp/qa.$$ >/dev/null 2>&1
  local PY=/tmp/qa.$$/bin/python
  [ -f requirements-dev.txt ] && $PY -m pip install -q -r requirements-dev.txt >/tmp/qpip.$$ 2>&1
  $PY -m pip install -q pytest requests >>/tmp/qpip.$$ 2>&1
  if ! $PY -c 'import pytest, requests' 2>/dev/null; then
    bad "qa:install" "the suite's dependencies do not install"; tail -10 /tmp/qpip.$$ >&2; return
  fi
  ok "qa:install" "the suite's dependencies install"

  export COMPOSE_PROJECT_NAME="qa-verify-$$" QA_IMAGE="$ref" QA_PORT="$PORT"
  if ! docker compose -f "$QA_COMPOSE" up -d --wait --wait-timeout 120 >/tmp/qup.$$ 2>&1; then
    bad "qa:up" "the stack does not come up healthy"; tail -15 /tmp/qup.$$ >&2
    docker compose -f "$QA_COMPOSE" down -v >/dev/null 2>&1
    return
  fi
  ok "qa:up" "the stack is up and healthy on $BASE"

  if QA_BASE_URL="$BASE" $PY -m pytest qa -q >/tmp/qpt.$$ 2>&1; then
    local n
    n=$(grep -oE '[0-9]+ passed' /tmp/qpt.$$ | head -1 | grep -oE '[0-9]+')
    ok "qa:runs" "${n:-?} scenario(s) green against the image your pipeline published"
  else
    bad "qa:runs" "the suite fails against the image your own pipeline published"
    tail -20 /tmp/qpt.$$ >&2
  fi

  docker compose -f "$QA_COMPOSE" down -v >/dev/null 2>&1
  rm -rf /tmp/qa.$$ /tmp/qpip.$$ /tmp/qpt.$$ /tmp/pull.$$ /tmp/qup.$$
}

#
# section: aqa — bonus. Scenarios of your own.
#
# The five scenarios in qa/test_smoke.py are given, so they are not graded here
# and they do not count towards anything. This section is about the thing QA
# actually owns: cases that came from somewhere, including the ones that only
# exist because something broke once.


section_aqa() {
  sect "how much it covers"
  [ -d qa ] || { bad "aqa:suite" "no qa/ folder"; return; }

  # the five given scenarios do not count: this bonus is the ones you added
  local own n
  own=$(find qa -name 'test_*.py' ! -name 'test_smoke.py' 2>/dev/null)
  if [ -z "$own" ]; then
    bad "aqa:scenarios" "only the given test_smoke.py is here — this bonus is scenarios of your own, in your own file"
    return
  fi
  n=$(grep -hoE '^def test_[A-Za-z0-9_]+' $own 2>/dev/null | wc -l | tr -d ' ')
  [ "${n:-0}" -ge 3 ] && ok "aqa:scenarios" "$n scenario(s) of your own, beside the five you were given" \
                      || bad "aqa:scenarios" "$n of your own — three is the bar, and the given five do not count"

  if grep -qE '== *(4[0-9][0-9]|5[0-9][0-9])|in *\( *4[0-9][0-9]|status_code *!= *200|raises' $own 2>/dev/null; then
    ok "aqa:negative" "one of yours asserts a failure, not a success"
  else
    bad "aqa:negative" "every case of yours expects things to work — a suite that cannot see a 404 or a 502 is half a suite"
  fi

  sect "where the cases came from"
  if [ -f qa/REGRESSION.md ]; then
    ok "aqa:regression-file" "qa/REGRESSION.md is there"
    local named=""
    local t
    for t in $(grep -rhoE 'def (test_[A-Za-z0-9_]+)' qa/ | sed 's/^def //'); do
      grep -q "$t" qa/REGRESSION.md && named="$t" && break
    done
    [ -n "$named" ] && ok  "aqa:regression-case" "it names the case that exists because of the incident ($named)" \
                    || bad "aqa:regression-case" "REGRESSION.md does not name any test in the suite — which case came from the incident?"
    local words
    words=$(wc -w < qa/REGRESSION.md | tr -d ' ')
    [ "${words:-0}" -ge 15 ] && ok "aqa:regression-told" "the incident is written down" \
                             || bad "aqa:regression-told" "two lines about what broke, please — a case with no story is a case nobody will keep"
  else
    bad "aqa:regression-file" "no qa/REGRESSION.md — one incident, two lines, and the case it produced"
  fi

  sect "how it runs"
  read_workflows || true
  local qa_files
  qa_files=$(grep '^QA ' <<<"$WFR" | sed 's/^QA //;s/:.*//' | sort -u)
  local text=""
  local f
  for f in $qa_files; do text+="$(cat "$WF/$f" 2>/dev/null)"; done
  [ -n "$text" ] || text=$(cat $WF/*.yml $WF/*.yaml 2>/dev/null)

  grep -q 'matrix:' <<<"$text" \
    && ok  "aqa:matrix" "the suite fans out over a matrix" \
    || bad "aqa:matrix" "one configuration only — a matrix is how the same suite covers two of them"

  grep -q 'upload-artifact' <<<"$text" \
    && ok  "aqa:artifact" "a report leaves the runner as an artifact" \
    || bad "aqa:artifact" "nothing is uploaded — when the suite fails at 02:00 the log is gone and the report is not"

  if grep -rqE 'check|required' qa/REGRESSION.md 2>/dev/null; then
    ok "aqa:checkname" "the check branch protection would require is named"
  else
    warn "aqa:checkname" "name the check a branch rule would require — that name is a job name, and it changes when the job is renamed"
  fi
}

#
# section: concurrency — bonus. The identifier, and the one place not to cancel.
#
# Two halves. The file has to name a group that means something, and the
# repository has to show a run that was really cancelled by it — because a
# concurrency block is the kind of thing everybody writes and nobody watches
# work.


section_concurrency() {
  sect "the group"
  read_workflows || true
  [ -n "$WFR" ] || { bad "conc:group" "the workflows do not parse"; return; }

  if ! grep -q '^CONC ' <<<"$WFR"; then
    bad "conc:group" "no concurrency: block anywhere — two pushes in a minute run two full pipelines"
    return
  fi
  ok "conc:group" "$(grep -c '^CONC ' <<<"$WFR") concurrency block(s)"

  local groups
  groups=$(grep '^CONC ' <<<"$WFR" | sed 's/.*group=//')
  if grep -q 'github\.\(ref\|head_ref\|ref_name\|event\.number\)' <<<"$groups"; then
    ok "conc:identifier" "the group is keyed on the ref, so one branch waits for itself and not for everybody"
  else
    bad "conc:identifier" "the group is a constant ($(head -1 <<<"$groups")) — that serialises the whole repository"
  fi

  grep -q 'github\.workflow' <<<"$groups" \
    && ok   "conc:workflow" "the workflow is part of the group, so two different pipelines do not collide" \
    || warn "conc:workflow" "add github.workflow to the group unless you meant two workflows to queue against each other"

  sect "and the place not to cancel"
  local risky=""
  local line
  while read -r line; do
    case "$line" in
      *cancel=True*) risky="$line" ;;
    esac
  done < <(grep '^CONC ' <<<"$WFR")

  if [ -z "$risky" ]; then
    ok "conc:not-main" "cancel-in-progress is never a bare true"
  elif grep -q "github.ref\|github.event_name\|!=" <<<"$(grep '^CONC ' <<<"$WFR" | sed 's/.*cancel=//')"; then
    ok "conc:not-main" "cancelling is decided by an expression, not switched on everywhere"
  else
    bad "conc:not-main" "cancel-in-progress: true with no condition — the next push kills a publish halfway through"
  fi

  sect "it is scoped to this lab"
  if grep -q '^PATHS ' <<<"$WFR"; then
    ok "paths:scoped" "$(grep '^PATHS ' <<<"$WFR" | head -1 | sed 's/^PATHS //')"
  else
    warn "paths:scoped" "no paths: filter — a README typo runs the whole pipeline"
  fi

  it_really_cancelled
  written_down
}

# A cancelled run is a fact in the API. Nothing in a YAML file proves one.
it_really_cancelled() {
  sect "a run that was really cancelled"
  if ! api_ready; then
    warn "conc:proof" "no token or repository — run this in Actions to grade it"; return
  fi

  local branch runs n
  branch="${GITHUB_HEAD_REF:-${GITHUB_REF_NAME:-}}"
  runs=$(gh_api --get --data-urlencode "branch=$branch" --data-urlencode "status=cancelled" \
                --data-urlencode "per_page=20" "$API/actions/runs")
  case "$(api_code)" in
    200) : ;;
    403) warn "conc:proof" "403 — the grading job needs permissions: actions: read"; return ;;
    *)   warn "conc:proof" "the runs API answered $(api_code)"; return ;;
  esac

  n=$(jq_py "$runs" "len(d.get('workflow_runs',[]))")
  if [ "${n:-0}" -ge 1 ]; then
    ok "conc:proof" "$n cancelled run(s) on '$branch' — the group did something"
  else
    bad "conc:proof" "no cancelled run on '$branch' — push twice in quick succession and watch the first one go"
  fi
}

written_down() {
  sect "what you saw"
  need_file CONCURRENCY.md
  [ -f CONCURRENCY.md ] || return

  local ids
  ids=$(grep -oE 'actions/runs/[0-9]+' CONCURRENCY.md | sort -u | wc -l | tr -d ' ')
  [ "${ids:-0}" -ge 2 ] && ok "conc:written" "$ids run URLs — the one that was cancelled and the one that cancelled it" \
                        || bad "conc:written" "paste both runs: the one that was cancelled and the one that replaced it"

  grep -qiE 'safe|because|would|lost|partial|deploy|publish' CONCURRENCY.md \
    && ok  "conc:why" "and why cancelling that one was safe" \
    || bad "conc:why" "one line on why it was safe to cancel that run — and where it would not have been"
}

# ── run it ───────────────────────────────────────────────────────────────────
[ "$LIB" = 1 ] && return 0

log "${B}catshop lab 3 · section: $SECTION${N}"
"section_$SECTION"
check_secrets                 # every section, always
rm -f /tmp/b.$$ /tmp/cb.$$ /tmp/cu.$$ "$API_CODE_FILE"

emit_report "$SECTION"

# A bonus section reports and exits clean: it can only ever add marks, so a red
# one must not show up as a failed check.
[ "$BONUS" = 1 ] && exit 0
[ "$FAIL" -eq 0 ]
