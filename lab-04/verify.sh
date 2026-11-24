#!/usr/bin/env bash
#
# verify.sh — grade ONE section of lab 4. Everything is in this file.
#
#   ./verify.sh --section config --path lab-04
#   ./verify.sh --section stack  --path lab-04 --json
#
#   config   the configuration judged from the files alone     required
#   stack    the place really comes up, and really goes away   required
#   drift    state against reality, and what plan notices      bonus
#
# `config` touches nothing: no server, no certificate, no state backend, which
# is what lets the course's own CI run it on every push against a known-good and
# a known-broken configuration.
#
# `stack` and `drift` really apply. On the course server the endpoint arrives as
# TF_VAR_docker_host — an ssh:// URL for a certificate this run was issued for an
# hour — and the state lives in the student's own HCP organization. Neither
# section may override those: doing so deploys onto the runner instead of onto
# the server the student is graded against.
#
# Flags: --path DIR · --port N · --json · --keep · --bonus
# Exit 0 = nothing failed. A WARN is a judgement call for the pull request.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECTION=""; WORKDIR=""; JSON="${JSON:-0}"; KEEP="${KEEP:-0}"; BONUS=0
LIB="${LAB04_LIB:-0}"          # 1 = only define the functions, for tests/run.sh

if [ "$LIB" = 0 ]; then
while [ $# -gt 0 ]; do
  case "$1" in
    --section) SECTION="${2:?--section needs a value}"; shift 2 ;;
    --path)    WORKDIR="${2:?--path needs a value}";    shift 2 ;;
    --port)    PORT="${2:?--port needs a value}";       shift 2 ;;
    --json)    JSON=1; shift ;;
    --keep)    KEEP=1; shift ;;
    --bonus)   BONUS=1; shift ;;   # report, never fail: a bonus cannot cost marks
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done
case "$SECTION" in
  config|stack|drift) : ;;
  "") echo "--section is required: config | stack | drift" >&2; exit 2 ;;
  *)  echo "unknown section '$SECTION'" >&2; exit 2 ;;
esac

if [ -n "$WORKDIR" ]; then
  cd "$WORKDIR" || { echo "no such path: $WORKDIR" >&2; exit 2; }
fi
fi

export JSON KEEP
# shellcheck source=../common/lib.sh
. "$HERE/../common/lib.sh"

TFDIR=terraform

# The lab fixes three names so one grader can read forty-two configurations:
# two input variables and one output. Everything else is the student's.
VAR_HOST=docker_host
VAR_PORT=port
OUT_URL=url

APPLIED=0        # 1 once this run has created real containers

tf_cleanup() {
  if [ "${KEEP:-0}" = 1 ]; then
    log "${D}left running — terraform -chdir=$TFDIR destroy${N}"
    return
  fi
  [ "$APPLIED" = 1 ] && terraform -chdir="$TFDIR" destroy -auto-approve -input=false \
    >/dev/null 2>&1 || true
  rm -f "$TFDIR/tfplan" 2>/dev/null || true
}
[ "$LIB" = 0 ] && trap tf_cleanup EXIT

# ── reading HCL ──────────────────────────────────────────────────────────────
# read_tf.py returns every top-level block with its labels and its body as text.
# Nothing here evaluates an expression: a check asks whether the text references
# `var.`, never what that resolves to.
TFJSON=""

read_tf() {  # read_tf <dir>
  TFJSON=$(python3 "$HERE/read_tf.py" "$1" 2>/dev/null)
  [ -n "$TFJSON" ] && [ "$TFJSON" != "null" ]
}

tfq() {  # tfq <python expression over `d`> — d is read_tf's object
  python3 - "$TFJSON" "$1" <<'PYEOF' 2>/dev/null
import json, re, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    d = {"files": [], "blocks": [], "text": ""}


def blocks(type_=None, label0=None):
    out = []
    for b in d["blocks"]:
        if type_ and b["type"] != type_:
            continue
        if label0 and (not b["labels"] or b["labels"][0] != label0):
            continue
        out.append(b)
    return out


def resources(pattern):
    """Resources whose TYPE matches a regex — the only provider-agnostic handle."""
    return [b for b in blocks("resource")
            if b["labels"] and re.search(pattern, b["labels"][0])]


def body_of(type_, label0=None):
    return "\n".join(b["body"] for b in blocks(type_, label0))


SIZE = r"(?m)^\s*(count|target_size|node_count|desired_capacity|instance_count|min_size)\s*=\s*(\S+)"


def var_default(name):
    """The value a variable falls back to, as written."""
    for b in blocks("variable", name):
        m = re.search(r"(?m)^\s*default\s*=\s*(\S+)", b["body"])
        if m:
            return m.group(1).strip().strip('"')
    return None


def two_of_them():
    """Two instances, however they were asked for.

    `target_size = 2` and `target_size = var.replicas` with a default of 2 are
    the same declaration, and the second one is the better written of the two.
    """
    for b in resources(r"(instance|server|droplet|virtual_machine|group)"):
        for _kw, val in re.findall(SIZE, b["body"]):
            val = val.strip().rstrip(",")
            if val == "2":
                return True
            m = re.fullmatch(r"var\.([A-Za-z_][A-Za-z0-9_]*)", val)
            if m and var_default(m.group(1)) == "2":
                return True
    singles = resources(r"(^aws_instance$|^google_compute_instance$|^hcloud_server$|^digitalocean_droplet$)")
    return len(singles) >= 2


env = {"d": d, "re": re, "blocks": blocks, "resources": resources, "two_of_them": two_of_them,
       "var_default": var_default,
       "body_of": body_of, "len": len, "any": any, "all": all, "sorted": sorted,
       "set": set, "str": str, "int": int, "sum": sum, "max": max}
try:
    print(eval(sys.argv[2], env))
except Exception as exc:
    print(f"ERR:{exc}")
PYEOF
}

tf_true() { [ "$(tfq "$1")" = "True" ]; }

# ── docker, before and after ─────────────────────────────────────────────────
# Container names belong to the student, so nothing here matches on a name. The
# check is a set difference: what existed before apply, and what exists after
# destroy. That is also the only honest way to ask "did destroy leave anything".
dsnap() {  # dsnap <kind>
  case "$1" in
    containers) docker ps -aq 2>/dev/null | sort ;;
    networks)   docker network ls -q 2>/dev/null | sort ;;
    volumes)    docker volume ls -q 2>/dev/null | sort ;;
  esac
}

SNAP_C=""; SNAP_N=""; SNAP_V=""
snap_before() { SNAP_C=$(dsnap containers); SNAP_N=$(dsnap networks); SNAP_V=$(dsnap volumes); }
leaked() {  # leaked <kind> <before> — ids present now that were not before
  comm -13 <(printf '%s\n' "$2") <(dsnap "$1") | grep -c . || true
}

# ── terraform ────────────────────────────────────────────────────────────────
TF_LOG_FILE="${TMPDIR:-/tmp}/tf.$$.log"

tf() {  # tf <dir> <args...> — quiet, output captured for the failure message
  local dir="$1"; shift
  terraform -chdir="$dir" "$@" >"$TF_LOG_FILE" 2>&1
}

tf_tail() { tail -n 6 "$TF_LOG_FILE" 2>/dev/null | tr '\n' ' ' | cut -c1-240; }

pick_port() {
  python3 - <<'PYEOF'
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0))
print(s.getsockname()[1]); s.close()
PYEOF
}

# Bring the student's stack up and leave the URL in $URL. Shared by two sections,
# because each section is its own job and cannot inherit the other's containers.
apply_stack() {
  local port
  # The course workflow has already exported TF_VAR_docker_host (an ssh:// URL
  # for this run's certificate), TF_VAR_port and TF_VAR_bind_ip. Overriding them
  # with a local socket, as this used to, would deploy the student's stack onto
  # the runner instead of onto the server they were graded against.
  port="${PORT:-${TF_VAR_port:-$(pick_port)}}"
  : "${TF_VAR_docker_host:=unix:///var/run/docker.sock}"
  : "${TF_VAR_bind_ip:=127.0.0.1}"
  export TF_VAR_docker_host TF_VAR_bind_ip
  export TF_VAR_${VAR_PORT}="$port"
  export TF_IN_AUTOMATION=1

  snap_before

  if tf "$TFDIR" init -input=false -no-color; then
    ok "tf:init" "providers downloaded and the folder initialised"
  else
    bad "tf:init" "terraform init failed — $(tf_tail)"; return 1
  fi

  if tf "$TFDIR" validate -no-color; then
    ok "tf:validate" "the configuration is valid"
  else
    bad "tf:validate" "terraform validate failed — $(tf_tail)"; return 1
  fi

  APPLIED=1
  if tf "$TFDIR" apply -auto-approve -input=false -no-color; then
    ok "tf:apply" "the stack was created from the configuration alone"
  else
    bad "tf:apply" "terraform apply failed — $(tf_tail)"; return 1
  fi

  URL=$(terraform -chdir="$TFDIR" output -raw "$OUT_URL" 2>/dev/null)
  if [ -n "$URL" ] && [ "${URL#http}" != "$URL" ]; then
    ok "tf:output" "output \`$OUT_URL\` is $URL"
  else
    # Without the output there is nothing to probe, so fall back to the port we
    # handed in rather than failing every behaviour check for one missing line.
    bad "tf:output" "no output \`$OUT_URL\` — the stack's address must come out of terraform"
    URL="http://localhost:$port"
  fi
  return 0
}

wait_for() {  # wait_for <url> <seconds>
  local i
  for i in $(seq 1 "${2:-60}"); do
    curl -sf -m 3 -H 'Connection: close' "$1" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

# Each request on its own connection. With keep-alive the client is pinned to
# whichever backend answered first and a correct two-replica stack looks like one.
hit() { curl -sS -m 5 -H 'Connection: close' "$@" 2>/dev/null; }
code_of() { curl -s -o /dev/null -w '%{http_code}' -m 5 -H 'Connection: close' "$1" 2>/dev/null; }

json_field() {  # json_field <json> <key>
  python3 - "$1" "$2" <<'PYEOF' 2>/dev/null
import json, sys
try:
    print(json.loads(sys.argv[1]).get(sys.argv[2], "") or "")
except Exception:
    print("")
PYEOF
}


# The state has to outlive the job on the local path, or "No changes." is a
# sentence that can never be true and half the lesson is missing.
check_remote_state() {
  if ! read_tf "$TFDIR"; then
    bad "state:read" "no .tf files under $TFDIR/"
    return
  fi
  # `backend "local"` matched the old check and is exactly the thing the lesson
  # is against, so the two cases are separated.
  if tf_true "re.search(r'(?m)^\\s*backend\\s+\"local\"', body_of('terraform')) is not None"; then
    bad "state:not-local" "backend \"local\" keeps the state beside the configuration — on a runner that is deleted, that is the same as no state"
    return
  fi
  if tf_true "re.search(r'(?m)^\\s*(cloud|backend)\\s', body_of('terraform')) is not None"; then
    ok "state:not-local" "the state is configured to live off this machine"
  else
    bad "state:not-local" "no cloud or backend block — with the state beside the configuration every run starts from nothing"
    return
  fi
  # Second plan on an unchanged world must be empty. This is the whole point of
  # keeping the state, and it cannot be faked by a configuration that works.
  tf "$TFDIR" plan -detailed-exitcode -input=false -no-color >/dev/null 2>&1
  case $? in
    0) ok "state:no-changes" "a second plan reports no changes — the state remembered" ;;
    2) bad "state:no-changes" "a second plan still wants to create things — the state did not survive the first apply" ;;
    *) bad "state:no-changes" "terraform plan failed — $(tf_tail)" ;;
  esac
}

# ── section: stack ───────────────────────────────────────────────────────────
#
# The configuration is graded twice over: once as text, because some of the
# lesson is invisible at run time (a pinned provider, a password that is not a
# literal, a template that follows `count`), and once by running it, because
# the rest of the lesson is invisible in the text.
# Everything that can be judged from the files alone. Split out so it can be
# graded without a server, a certificate or a state backend — which is what
# lets the course's own CI check these rules against a known-good and a
# known-broken configuration on every push.
stack_text_checks() {
  need_file "$TFDIR/main.tf"
  need_file "$TFDIR/variables.tf"
  need_file "$TFDIR/outputs.tf"
  need_file "$TFDIR/backend.tf"
  need_file "$TFDIR/nginx.conf.tftpl"

  if ! read_tf "$TFDIR"; then
    bad "tf:read" "no .tf files under $TFDIR/ — there is nothing to grade"
    return 1
  fi

  tf_true 're.search(r"required_version", body_of("terraform")) is not None' \
    && ok "hcl:required-version" "the Terraform version is pinned" \
    || bad "hcl:required-version" "no required_version — the language itself is a dependency"

  tf_true 're.search(r"kreuzwerker/docker", d["text"]) is not None' \
    && ok "hcl:provider-source" "the docker provider is sourced explicitly" \
    || bad "hcl:provider-source" "required_providers must name kreuzwerker/docker"

  tf_true 're.search(r"kreuzwerker/docker\"[\s\S]{0,200}?version\s*=|version\s*=[\s\S]{0,200}?kreuzwerker/docker", d["text"]) is not None' \
    && ok "hcl:provider-version" "the provider is pinned at a version" \
    || bad "hcl:provider-version" "pin the provider version — today's registry is not next month's"

  tf_true "re.search(r'var\\.', body_of('provider', 'docker')) is not None" \
    && ok "hcl:host-variable" "the daemon endpoint comes from a variable" \
    || bad "hcl:host-variable" "provider \"docker\" must take host from a variable — the course workflow sets TF_VAR_docker_host"

  tf_true "len(resources(r'^docker_network$')) >= 1" \
    && ok "hcl:network" "a docker_network is declared" \
    || bad "hcl:network" "no docker_network — the containers need a place to find each other by name"

  tf_true "len(resources(r'^docker_volume$')) >= 1" \
    && ok "hcl:volume" "a docker_volume is declared" \
    || bad "hcl:volume" "no docker_volume — a volume is part of the place, and destroy has to take it away again"

  tf_true "any(re.search(r'(?m)^\\s*count\\s*=', b['body']) for b in resources(r'^docker_container$'))" \
    && ok "hcl:count" "the replicas come from one resource with count" \
    || bad "hcl:count" "two copy-pasted container blocks are not two replicas — use count on one resource"

  tf_true "re.search(r'templatefile\\s*\\(', d['text']) is not None" \
    && ok "hcl:templatefile" "the proxy configuration is rendered, not pasted" \
    || bad "hcl:templatefile" "nginx.conf.tftpl must be rendered with templatefile(...)"

  # This lab builds nothing. An image built here would put a Dockerfile, a
  # build context and several minutes of CPU on a shared server for no lesson.
  tf_true "not any(re.search(r'(?m)^\\s*build\\s*\\{', b['body']) for b in resources(r'^docker_image$'))" \
    && ok "hcl:no-build" "no image is built — public images only in this lab" \
    || bad "hcl:no-build" "a build block belongs to the next lab; use nginx:1.27-alpine with keep_locally"

  # A port bound to every address on a shared machine bypasses the proxy that
  # serves everyone's URL, and is reachable by anything that can route to the box.
  tf_true "any(re.search(r'(?m)^\\s*ip\\s*=\\s*var\\.', b['body']) for b in resources(r'^docker_container$'))" \
    && ok "hcl:bind-ip" "the published port is bound to the address the workflow gives you" \
    || bad "hcl:bind-ip" "ports { ... ip = var.bind_ip } — on a shared server a container on 0.0.0.0 is a second front door"

  tf_true "len(resources(r'^(null_resource|terraform_data)$')) == 0 and re.search(r'local-exec|remote-exec', d['text']) is None" \
    && ok "hcl:no-shell" "nothing is created by shelling out" \
    || bad "hcl:no-shell" "local-exec, remote-exec or null_resource — that is a script wearing Terraform's coat"

  tf_true "re.search(r'(?m)^\\s*output\\s+\"url\"', d['text']) is not None" \
    && ok "hcl:output-url" "the stack's address comes out of terraform" \
    || bad "hcl:output-url" "no output \"url\" — one grader reads thirty-two configurations and that name is fixed"

  # A template that names the backends by hand looks right and silently ignores
  # `count`, which is the single most common way to get this lab wrong.
  if [ -f "$TFDIR/nginx.conf.tftpl" ]; then
    if grep -qE '\$\{|%\{' "$TFDIR/nginx.conf.tftpl"; then
      ok "tpl:interpolated" "the upstream list is generated from the resource"
    else
      bad "tpl:interpolated" "nginx.conf.tftpl has no interpolation — raise count to three and nothing changes"
    fi
    grep -qiE 'upstream\s|proxy_pass' "$TFDIR/nginx.conf.tftpl" \
      && ok "tpl:upstream" "an upstream pool and a proxy_pass rule are present" \
      || bad "tpl:upstream" "no upstream / proxy_pass — this file is the proxy"
  fi
  return 0
}

# ── section: config ──────────────────────────────────────────────────────────
#
# The text, and only the text. No apply, no server, no state.
section_config() {
  sect "section config — what the files say"
  stack_text_checks || return
  if ! read_tf "$TFDIR"; then return; fi
  if tf_true "re.search(r'(?m)^\\s*backend\\s+\"local\"', body_of('terraform')) is not None"; then
    bad "state:not-local" "backend \"local\" keeps the state beside the configuration — on a runner that is deleted, that is the same as no state"
  elif tf_true "re.search(r'(?m)^\\s*cloud\\s*\\{', body_of('terraform')) is not None"; then
    ok "state:cloud" "a cloud block is declared, so the state outlives the runner"
  else
    bad "state:cloud" "backend.tf must declare an empty cloud block, so the organization and workspace come from the environment"
  fi
}

section_stack() {
  sect "section stack — a proxy, two replicas, a volume"

  stack_text_checks || return

  # ---- what the file does --------------------------------------------------
  apply_stack || return

  if wait_for "$URL/health" 90; then
    ok "run:health" "the stack answers /health through the proxy"
  else
    bad "run:health" "nothing answered $URL/health within 90s"
    return
  fi

  # On the course server the URL is https://<host>/<github-login>/, and the
  # login in it has to be the owner of the repository being graded. Otherwise a
  # correct-looking run could be probing somebody else's stack.
  if [ "${URL#https://}" != "$URL" ] && [ -n "${GITHUB_REPOSITORY_OWNER:-}" ]; then
    if printf '%s' "$URL" | grep -qi "/${GITHUB_REPOSITORY_OWNER}/\?\$"; then
      ok "run:own-url" "the URL belongs to $GITHUB_REPOSITORY_OWNER"
    else
      bad "run:own-url" "$URL is not this repository owner's address — a stack is graded at its own URL or not at all"
    fi
  fi

  # Separate connections, because keep-alive pins the client to whichever
  # backend answered first and a correct two-replica stack then looks like one.
  #
  # This RETRIES for up to 45s, and that is not padding. A proxy with max_fails
  # set will exclude a backend that failed once — including one that was merely
  # slow to start — and let it back in after fail_timeout. Measured on a clean
  # apply: all requests hit a single replica for the first ~30s, then settled to
  # an even split. A fixed loop straight after /health answers fails a correct
  # configuration.
  local seen i who distinct=0 waited=0
  while [ "$waited" -lt 45 ]; do
    seen=""
    for i in $(seq 1 12); do
      # nginx answers /whoami with its own $hostname, one bare line. No JSON,
      # because this lab has no application in it.
      who=$(hit "$URL/whoami" | tr -d '\r' | head -1)
      [ -n "$who" ] && seen="$seen$who"$'\n'
    done
    distinct=$(printf '%s' "$seen" | sort -u | grep -c . || true)
    [ "${distinct:-0}" -ge 2 ] && break
    sleep 5
    waited=$((waited+5))
  done
  if [ "${distinct:-0}" -ge 2 ]; then
    ok "run:replicas" "$distinct distinct replicas answered (settled after ${waited}s)"
  elif [ "${distinct:-0}" = 1 ]; then
    bad "run:replicas" "every request reached the same copy — one replica, or the pool has one entry"
  else
    bad "run:replicas" "/whoami returned nothing — is the proxy forwarding to the replicas?"
  fi

  # ---- and whether anything was remembered ---------------------------------
  check_remote_state

  # ---- and what it takes away ----------------------------------------------
  if tf "$TFDIR" destroy -auto-approve -input=false -no-color; then
    APPLIED=0
    ok "tf:destroy" "terraform destroy completed"
    local lc ln lv
    lc=$(leaked containers "$SNAP_C"); ln=$(leaked networks "$SNAP_N"); lv=$(leaked volumes "$SNAP_V")
    if [ "$lc" = 0 ] && [ "$ln" = 0 ] && [ "$lv" = 0 ]; then
      ok "tf:clean" "nothing survived destroy"
    else
      bad "tf:clean" "left behind: $lc container(s), $ln network(s), $lv volume(s) — Terraform does not know about what it did not create"
    fi
  else
    bad "tf:destroy" "terraform destroy failed — $(tf_tail)"
  fi
}

# ── section: drift ───────────────────────────────────────────────────────────
#
# The whole section is one experiment: change the world behind Terraform's back
# and look at both sides. The load balancer should not care, and plan should.
section_drift() {
  sect "section drift — what the state believes, and what the machine is doing"

  need_file DRIFT.md

  if ! read_tf "$TFDIR"; then
    bad "tf:read" "no .tf files under $TFDIR/"
    return
  fi

  # A state file in the history is a leaked password, and no later commit fixes
  # it — which is the point worth making while they still have one lab to go.
  if git -C . log --all --pretty=format: --name-only -- '*.tfstate' '*.tfstate.*' 2>/dev/null \
       | grep -q . ; then
    bad "git:no-state" "a .tfstate file exists in the history — every attribute in it is public now"
  else
    ok "git:no-state" "no state file has ever been committed"
  fi

  if git -C . check-ignore -q --no-index "$TFDIR/terraform.tfstate" 2>/dev/null; then
    ok "git:ignored" "*.tfstate is ignored"
  else
    bad "git:ignored" "nothing ignores *.tfstate — it is one careless \`git add .\` away"
  fi

  apply_stack || return
  wait_for "$URL/health" 90 || { bad "run:health" "the stack never answered before the experiment"; return; }

  # Pick the first counted container out of the state, so the name stays the
  # student's business.
  local addr name
  addr=$(terraform -chdir="$TFDIR" state list 2>/dev/null \
         | grep '^docker_container\.' | grep '\[0\]' | head -1)
  [ -z "$addr" ] && addr=$(terraform -chdir="$TFDIR" state list 2>/dev/null \
         | grep '^docker_container\.' | head -1)
  if [ -z "$addr" ]; then
    bad "drift:target" "no docker_container in the state to stop"
    return
  fi
  name=$(terraform -chdir="$TFDIR" state show "$addr" 2>/dev/null \
         | sed -n 's/^[[:space:]]*name[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' | head -1)
  if [ -z "$name" ] || ! docker stop "$name" >/dev/null 2>&1; then
    bad "drift:target" "could not stop a replica ($addr)"
    return
  fi
  ok "drift:target" "stopped $name by hand — Terraform was not told"

  # nginx retries the next upstream on a refused connection, so the client never
  # sees the dead one. That is the behaviour, not a detail of the grader.
  local i good=0
  for i in $(seq 1 20); do
    [ "$(code_of "$URL/health")" = "200" ] && good=$((good+1))
  done
  if [ "$good" = 20 ]; then
    ok "drift:still-serving" "20 of 20 requests answered with one replica down"
  elif [ "$good" -ge 17 ]; then
    warn "drift:still-serving" "$good of 20 answered — the misses are the window before the proxy excluded the dead backend; say so in the pull request"
  else
    bad "drift:still-serving" "$good of 20 answered — a stopped container does not refuse connections, it stops answering. Without proxy_connect_timeout the failover you configured never runs in time"
  fi

  # -detailed-exitcode: 0 no changes, 1 error, 2 changes. The wrapper that
  # setup-terraform installs by default swallows this, which is why the action
  # turns it off.
  tf "$TFDIR" plan -detailed-exitcode -input=false -no-color -out=tfplan
  local rc=$?
  if [ "$rc" = 2 ]; then
    ok "drift:plan-notices" "plan reports a difference between the state and the machine"
  elif [ "$rc" = 0 ]; then
    bad "drift:plan-notices" "plan reported no changes — nothing is reading the real world back"
  else
    bad "drift:plan-notices" "terraform plan failed — $(tf_tail)"
    return
  fi

  local changes
  changes=$(terraform -chdir="$TFDIR" show -json tfplan 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(-1); raise SystemExit
n = sum(1 for r in d.get("resource_changes", [])
        if r.get("change", {}).get("actions") not in (["no-op"], ["read"]))
print(n)')
  if [ "$changes" = 1 ]; then
    ok "drift:one-resource" "exactly one resource is proposed for repair"
  elif [ "$changes" = "-1" ]; then
    warn "drift:one-resource" "could not read the plan back as JSON"
  else
    bad "drift:one-resource" "$changes resources would change — one container stopped should be one resource"
  fi

  # The write-up carries the part no script can see: what they understood.
  local body
  body=$(tr '[:upper:]' '[:lower:]' < DRIFT.md 2>/dev/null)
  case "$body" in
    *plan*) ok "doc:plan-line" "DRIFT.md records what plan printed" ;;
    *)      bad "doc:plan-line" "DRIFT.md must quote the plan line as it printed" ;;
  esac
  if [ "$(wc -w < DRIFT.md 2>/dev/null || echo 0)" -ge 80 ]; then
    ok "doc:written" "DRIFT.md is a write-up, not a placeholder"
  else
    bad "doc:written" "DRIFT.md is too short to contain the experiment"
  fi
}


# ── run ──────────────────────────────────────────────────────────────────────
if [ "$LIB" = 0 ]; then
  case "$SECTION" in
    config)     section_config ;;
    stack)      section_stack ;;
    drift)      section_drift ;;
  esac
  emit_report "$SECTION"
  [ "${BONUS:-0}" = 1 ] && exit 0
  [ "$FAIL" -gt 0 ] && exit 1
  exit 0
fi
