#!/usr/bin/env bash
#
# verify.sh — grade ONE section of lab 4. Everything is in this file.
#
#   ./verify.sh --section stack --path lab-04
#   ./verify.sh --section cloud-plan --path lab-04 --json
#
#   stack        the declared stack really comes up, and really goes away   required
#   drift        state against reality, and what plan notices               required
#   cloud-plan   the same shape for a cloud, validated with no account      required
#   deployed     a real URL, running the commit being graded                bonus
#
# Two of these sections really run `terraform apply` on this runner. There is no
# cloud account anywhere and no secret: the provider is `kreuzwerker/docker` and
# the endpoint is the runner's own daemon. `cloud-plan` never leaves `validate`,
# which is offline, so it needs no credentials either.
#
# `deployed` is the only check that leaves the machine. It probes a URL the
# student published, over the public internet, and the check that makes it mean
# anything is that /version must return the commit being graded.
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
  stack|drift|cloud-plan|deployed) : ;;
  "") echo "--section is required: stack | drift | cloud-plan | deployed" >&2; exit 2 ;;
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
CLOUDDIR=cloud
DEPLOYDIR=deploy

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
  rm -f "$TFDIR/tfplan" "$CLOUDDIR/tfplan" 2>/dev/null || true
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


env = {"d": d, "re": re, "blocks": blocks, "resources": resources,
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
  port="${PORT:-$(pick_port)}"
  export TF_VAR_${VAR_HOST}="unix:///var/run/docker.sock"
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


# ── which of the two paths was taken ─────────────────────────────────────────
#
# The lab accepts either proof, and they are not the same work:
#
#   local   the stack really applies here, and the state is kept somewhere that
#           outlives the runner
#   remote  it is deployed on their own account and answers on a public URL
#
# A published URL is the signal, because it is the thing only the remote path
# can produce. Nothing asks the student to declare which one they chose.
chosen_path() {
  [ -s "$DEPLOYDIR/url.txt" ] && { echo remote; return; }
  echo local
}

# The state has to outlive the job on the local path, or "No changes." is a
# sentence that can never be true and half the lesson is missing.
check_remote_state() {
  if ! read_tf "$TFDIR"; then
    bad "state:read" "no .tf files under $TFDIR/"
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
section_stack() {
  if [ "$(chosen_path)" = remote ]; then
    sect "section stack — deployed, on your own account"
    section_deployed_core
    return
  fi
  sect "section stack — a load balancer, two replicas, one database"

  need_file "$TFDIR/main.tf"
  need_file "$TFDIR/variables.tf"
  need_file "$TFDIR/outputs.tf"
  need_file "$TFDIR/nginx.conf.tftpl"
  need_file Dockerfile

  if ! read_tf "$TFDIR"; then
    bad "tf:read" "no .tf files under $TFDIR/ — there is nothing to grade"
    return
  fi

  # ---- what the file says --------------------------------------------------
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
    || bad "hcl:host-variable" "provider \"docker\" must take host from a variable — a laptop path is not a default"

  tf_true "len(resources(r'^docker_network$')) >= 1" \
    && ok "hcl:network" "a docker_network is declared" \
    || bad "hcl:network" "no docker_network — the containers need a place to find each other by name"

  tf_true "any(re.search(r'(?m)^\\s*count\\s*=', b['body']) for b in resources(r'^docker_container$'))" \
    && ok "hcl:count" "the replicas come from one resource with count" \
    || bad "hcl:count" "two copy-pasted container blocks are not two replicas — use count on one resource"

  tf_true "re.search(r'templatefile\\s*\\(', d['text']) is not None" \
    && ok "hcl:templatefile" "the proxy configuration is rendered, not pasted" \
    || bad "hcl:templatefile" "nginx.conf.tftpl must be rendered with templatefile(...)"

  tf_true "len(resources(r'^random_password$')) >= 1" \
    && ok "hcl:random-password" "the database password is generated" \
    || bad "hcl:random-password" "a literal password in the file is a password in the repository"

  tf_true "len(resources(r'^(null_resource|terraform_data)$')) == 0 and re.search(r'local-exec|remote-exec', d['text']) is None" \
    && ok "hcl:no-shell" "nothing is created by shelling out" \
    || bad "hcl:no-shell" "local-exec, remote-exec or null_resource — that is a script wearing Terraform's coat"

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
      || bad "tpl:upstream" "no upstream / proxy_pass — this file is the load balancer"
  fi

  # ---- what the file does --------------------------------------------------
  apply_stack || return

  if wait_for "$URL/health" 90; then
    ok "run:health" "the stack answers /health through the load balancer"
  else
    bad "run:health" "nothing answered $URL/health within 90s"
    return
  fi

  # Separate connections, because keep-alive pins the client to whichever backend
  # answered first and a correct two-replica stack then looks like one.
  #
  # This RETRIES for up to 45s, and that is not padding. A proxy with
  # max_fails set will exclude a backend that failed once — including one that
  # was merely slow to start — and let it back in after fail_timeout. Measured
  # on a clean apply: all requests hit a single replica for the first ~30s,
  # then settled to an even split. A fixed loop straight after /health answers
  # fails a correct configuration.
  local seen i who distinct=0 waited=0
  while [ "$waited" -lt 45 ]; do
    seen=""
    for i in $(seq 1 12); do
      who=$(json_field "$(hit "$URL/whoami")" instance)
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
    bad "run:replicas" "/whoami returned nothing — is the proxy forwarding to the app?"
  fi

  # Two replicas that do not share a database are two applications.
  local v1 v2 store
  v1=$(json_field "$(hit "$URL/visits")" visits)
  v2=$(json_field "$(hit "$URL/visits")" visits)
  store=$(json_field "$(hit "$URL/visits")" store)
  if [ "$store" = "postgres" ]; then
    ok "run:store" "the counter is in Postgres, not in a file inside a replica"
  else
    bad "run:store" "store is '${store:-unset}' — set DATABASE_URL so both copies count into the same place"
  fi
  if [ -n "$v1" ] && [ -n "$v2" ] && [ "$v2" -gt "$v1" ] 2>/dev/null; then
    ok "run:shared-state" "the count carries across replicas ($v1 then $v2)"
  else
    bad "run:shared-state" "the count did not advance across requests — each copy is keeping its own"
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

# The remote path, as graded by `stack`. Identical checks to the bonus, so the
# two paths are marked on the same scale rather than on sympathy.
section_deployed_core() {
  section_deployed
  if [ -d "$CLOUDDIR" ] || [ -d "$DEPLOYDIR" ]; then
    read_tf "$DEPLOYDIR" || read_tf "$CLOUDDIR" || true
    cloud_checks
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


# ── the cloud assertions, shared by cloud-plan and the remote path ───────────
#
# Which cloud is detected from the resource types, never asked for. The shared
# checks are the architecture; after them each cloud gets the two or three
# traps that are only traps on that cloud.
cloud_checks() {
  local cloud
  cloud=$(tfq "'google' if resources(r'^google_') else ('aws' if resources(r'^aws_') else ('azure' if resources(r'^azurerm_') else 'other'))")
  ok "cloud:provider" "reading this as ${cloud}"

  tf_true "len(resources(r'(load_?balancer|_lb$|_alb|forwarding_rule|target_pool|loadbalancer)')) >= 1" \
    && ok "cloud:load-balancer" "a load balancer is declared" \
    || bad "cloud:load-balancer" "no load balancer resource — that is the way in"

  tf_true "len(resources(r'(instance|server|droplet|virtual_machine|_vm$)')) - len(resources(r'(sql|database|_db_|rdb|postgres|mysql)')) >= 1" \
    && ok "cloud:compute" "compute is declared" \
    || bad "cloud:compute" "no instance, server or droplet — nothing is running the image"

  tf_true "any(re.search(r'(?m)^\\s*(count|target_size|node_count|desired_capacity|instance_count|min_size)\\s*=\\s*2', b['body']) for b in resources(r'(instance|server|droplet|virtual_machine|group)')) or len(resources(r'(^aws_instance$|^google_compute_instance$|^hcloud_server$|^digitalocean_droplet$)')) >= 2" \
    && ok "cloud:two" "there are two of them" \
    || bad "cloud:two" "one instance is not redundancy — declare two, by count or by group size"

  tf_true "len(resources(r'(sql_database_instance|db_instance|rds|database_cluster|rdb_instance|postgresql|mysql_)')) >= 1" \
    && ok "cloud:database" "a managed database is declared" \
    || bad "cloud:database" "no managed database"

  tf_true "re.search(r'/health', d['text']) is not None and re.search(r'health', d['text'], re.I) is not None" \
    && ok "cloud:health-check" "a health check is declared against /health" \
    || bad "cloud:health-check" "declare the health check, and point it at /health"

  case "$cloud" in
    google)
      # Health checks arrive from two fixed Google ranges, never from the load
      # balancer. Miss them and every backend is unhealthy with nothing in any log.
      tf_true "'35.191.0.0/16' in d['text'] and '130.211.0.0/22' in d['text']" \
        && ok "gcp:health-ranges" "the firewall allows 35.191.0.0/16 and 130.211.0.0/22" \
        || bad "gcp:health-ranges" "nothing allows Google's health-check ranges — every backend will be unhealthy and no log will say why"

      tf_true "len(resources(r'^google_compute_firewall$')) >= 1" \
        && ok "gcp:firewall" "firewall rules are declared" \
        || bad "gcp:firewall" "no google_compute_firewall — the network denies ingress by default"

      # A private Cloud SQL address needs a peering, and it is the resource
      # nobody draws.
      if tf_true "len(resources(r'^google_sql_database_instance$')) >= 1"; then
        tf_true "len(resources(r'^google_service_networking_connection$')) >= 1 or 'ipv4_enabled' in d['text']" \
          && ok "gcp:db-reachable" "the database's addressing is declared" \
          || warn "gcp:db-reachable" "a private Cloud SQL address needs google_service_networking_connection — say how yours is reached"
      fi

      tf_true "len(resources(r'^google_compute_router_nat$')) == 0" \
        && ok "gcp:no-nat" "no Cloud NAT" \
        || warn "gcp:no-nat" "Cloud NAT is ~\$33 a month — justify it in COST.md, or give the instances public addresses"
      ;;
    aws)
      # An ALB will not create at all with one subnet, and the error arrives at
      # apply rather than at plan.
      tf_true "len(resources(r'^aws_subnet$')) >= 2 or any('subnets' in b['body'] for b in resources(r'^aws_lb$'))" \
        && ok "aws:two-subnets" "more than one subnet — an ALB needs at least two, in different zones" \
        || bad "aws:two-subnets" "an ALB requires subnets in two availability zones and will not create with one"

      tf_true "len(resources(r'^aws_lb_target_group$')) >= 1" \
        && ok "aws:target-group" "a target group is declared" \
        || bad "aws:target-group" "no aws_lb_target_group — that is the pool"

      tf_true "len(resources(r'^aws_lb_listener$')) >= 1" \
        && ok "aws:listener" "a listener is declared" \
        || bad "aws:listener" "no aws_lb_listener — nothing is listening on the load balancer"

      tf_true "len(resources(r'^aws_security_group$')) >= 1" \
        && ok "aws:security-group" "security groups are declared" \
        || bad "aws:security-group" "no security group — the instances accept nothing, including the load balancer"

      tf_true "len(resources(r'nat_gateway')) == 0" \
        && ok "aws:no-nat" "no NAT gateway" \
        || bad "aws:no-nat" "a NAT gateway is ~\$32 a month PER ZONE that nobody in this exercise chose"
      ;;
  esac

  local ndata
  ndata=$(tfq "len(blocks('data'))")
  if [ "${ndata:-0}" != "0" ]; then
    warn "cloud:data-sources" "$ndata data source(s) — say how each resolves without an API call"
  else
    ok "cloud:data-sources" "nothing has to be looked up to read this file"
  fi
}

# ── section: cloud-plan ──────────────────────────────────────────────────────
#
# Same architecture, written for a cloud, graded without an account. `validate`
# is offline; `plan` is not, which is why this section stops at validate and the
# real apply lives in the bonus.
section_cloud_plan() {
  sect "section cloud-plan — the same three things, rented"

  need_file "$CLOUDDIR/main.tf"
  need_file "$CLOUDDIR/variables.tf"
  need_file COST.md

  if ! read_tf "$CLOUDDIR"; then
    bad "tf:read" "no .tf files under $CLOUDDIR/ — there is nothing to grade"
    return
  fi

  if tf "$CLOUDDIR" init -backend=false -input=false -no-color; then
    ok "cloud:init" "the provider resolves with no backend and no account"
  else
    bad "cloud:init" "terraform init -backend=false failed — $(tf_tail)"
    return
  fi

  if tf "$CLOUDDIR" validate -no-color; then
    ok "cloud:validate" "valid with no credentials present anywhere"
  else
    bad "cloud:validate" "terraform validate failed — $(tf_tail)"
  fi

  cloud_checks

  # COST.md is a third of the point: a declared architecture you cannot price is
  # an architecture you have not understood.
  if grep -qE '\$[0-9]' COST.md 2>/dev/null && grep -qiE 'month' COST.md 2>/dev/null; then
    ok "doc:cost" "COST.md prices the file per month"
  else
    bad "doc:cost" "COST.md needs real figures — a dollar amount per resource, per month"
  fi
  if [ "$(grep -cE '^\s*[-|*]|^\s*\|' COST.md 2>/dev/null || echo 0)" -ge 4 ]; then
    ok "doc:cost-itemised" "the cost is broken down, not a single number"
  else
    bad "doc:cost-itemised" "itemise it — one line per resource, then the total at rest"
  fi
}

# ── section: deployed · bonus ────────────────────────────────────────────────
#
# Provider-agnostic by construction. Nothing here asks which cloud it is or
# calls anybody's API: it probes a URL the student published. The check that
# makes the whole thing mean something is /version — the running code must be
# the commit being graded, which no screenshot and no stale deployment can fake.
section_deployed() {
  sect "section deployed (bonus) — a real URL, running this commit"

  if [ ! -f "$DEPLOYDIR/url.txt" ]; then
    bad "deployed:url" "no $DEPLOYDIR/url.txt — one line, the https URL, nothing else"
    return
  fi
  local url
  url=$(head -1 "$DEPLOYDIR/url.txt" | tr -d ' \t\r"' )
  url="${url%/}"
  case "$url" in
    https://*) ok "deployed:url" "$url" ;;
    http://*)  bad "deployed:url" "http:// — the certificate is part of the exercise"; return ;;
    *)         bad "deployed:url" "'$url' is not a URL"; return ;;
  esac

  # No -k anywhere. A self-signed certificate is a failed check, not a warning.
  if curl -sS --fail --proto '=https' -m 25 -o /dev/null "$url/health" 2>/dev/null; then
    ok "deployed:tls" "the certificate verifies and /health answers 200"
  else
    if curl -sS --fail --proto '=https' --insecure -m 25 -o /dev/null "$url/health" 2>/dev/null; then
      bad "deployed:tls" "it answers, but the certificate does not verify"
    else
      bad "deployed:tls" "$url/health did not answer 200 over verified https"
    fi
    return
  fi

  local sha want
  sha=$(json_field "$(curl -sS --fail -m 25 "$url/version" 2>/dev/null)" sha)
  want="${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null)}"
  if [ -z "$sha" ] || [ "$sha" = "unknown" ]; then
    bad "deployed:version" "/version says '${sha:-nothing}' — build the sha in with --build-arg GIT_SHA"
  elif [ -n "$want" ] && [ "${sha:0:7}" = "${want:0:7}" ]; then
    ok "deployed:version" "it is running ${sha:0:7}, the commit being graded"
  else
    bad "deployed:version" "it is running ${sha:0:7}, the graded commit is ${want:0:7} — deploy this one"
  fi

  if [ -f "$DEPLOYDIR/outputs.json" ]; then
    local out_url
    out_url=$(python3 - "$DEPLOYDIR/outputs.json" <<'PYEOF' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print(""); raise SystemExit
for v in d.values() if isinstance(d, dict) else []:
    s = v.get("value") if isinstance(v, dict) else v
    if isinstance(s, str) and s.startswith("http"):
        print(s.rstrip("/")); break
PYEOF
)
    if [ -z "$out_url" ]; then
      bad "deployed:terraform" "no http value in outputs.json — the address must come out of terraform output"
    elif [ "$out_url" = "$url" ]; then
      ok "deployed:terraform" "terraform output and url.txt agree"
    else
      bad "deployed:terraform" "terraform output says $out_url, url.txt says $url"
    fi
  else
    bad "deployed:terraform" "no $DEPLOYDIR/outputs.json — commit \`terraform output -json\`"
  fi

  # Every provider names this header differently, so a miss is something to
  # explain rather than something to lose. The lesson is that it is there at all.
  local who ff
  who=$(curl -sS --fail -m 25 "$url/whoami" 2>/dev/null)
  ff=$(json_field "$who" forwarded_for)
  if [ -n "$ff" ]; then
    ok "deployed:proxy" "something is in front of you — X-Forwarded-For is set"
  else
    warn "deployed:proxy" "no X-Forwarded-For — say in the pull request which header your provider uses instead"
  fi
}

# ── run ──────────────────────────────────────────────────────────────────────
if [ "$LIB" = 0 ]; then
  case "$SECTION" in
    stack)      section_stack ;;
    drift)      section_drift ;;
    cloud-plan) section_cloud_plan ;;
    deployed)   section_deployed ;;
  esac
  emit_report "$SECTION"
  [ "${BONUS:-0}" = 1 ] && exit 0
  [ "$FAIL" -gt 0 ] && exit 1
  exit 0
fi
