#!/usr/bin/env bash
# Secret checks. These run in EVERY section — a leaked credential is never bonus.

check_secrets() {
  sect "secrets"

  if git rev-parse --git-dir >/dev/null 2>&1; then
    git ls-files --error-unmatch .env >/dev/null 2>&1 \
      && bad "secret:env-tracked" ".env is COMMITTED — remove it and rotate the value" \
      || ok  "secret:env-tracked" ".env is not tracked"

    # the whole history, not just the working tree: a secret that was ever
    # committed is a leaked secret. This needs fetch-depth: 0 in CI.
    git log --all --name-only --pretty=format: 2>/dev/null | sort -u | grep -qx '.env' \
      && bad "secret:env-history" ".env appears in git HISTORY" \
      || ok  "secret:env-history" ".env never committed"

    # ask git rather than grepping one .gitignore: the rule may live in any of
    # them, or in .git/info/exclude, and we may be in a subdirectory
    git check-ignore -q .env 2>/dev/null \
      && ok  "secret:gitignore" ".env is git-ignored" \
      || bad "secret:gitignore" ".env is not ignored by git — add it to .gitignore"
  else
    warn "secret:git" "not a git repository"
  fi

  if [ -f Dockerfile ]; then
    # comments are stripped first: "nothing secret is baked in here" is
    # documentation, not a leak. We want an assignment with a literal value.
    if grep -vE '^[[:space:]]*#' Dockerfile \
       | grep -qiE '(password|secret|api[_-]?key|token)[[:space:]]*=[[:space:]]*[^$[:space:]]'; then
      bad "secret:dockerfile" "a secret-looking value is assigned in the Dockerfile"
    else
      ok "secret:dockerfile" "no secrets baked into the Dockerfile"
    fi
  fi

  if [ -f "$COMPOSE" ]; then
    if grep -nE '(PASSWORD|SECRET)[: =]+[^$#[:space:]]' "$COMPOSE" | grep -vq '\${'; then
      bad "secret:compose" "a literal password in $COMPOSE — use \${POSTGRES_PASSWORD} and .env"
    else
      ok "secret:compose" "no literal passwords in $COMPOSE"
    fi
  fi
}
