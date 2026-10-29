#!/usr/bin/env bash
#
# section: tests — a suite that runs, passes, and actually tests the application.
#
# The hard part of grading a test suite is that `assert True` passes. So this
# section asks three different questions: does it run, does it touch the app at
# all, and does it still pass when the app is broken on purpose.

section_run() {
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
