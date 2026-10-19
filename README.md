# catshop-grader

The checks that mark every lab in **CI/CD and Cloud Deployment of E-commerce Applications** (KSE,
autumn 2026). Students reference this repository from their own pipeline; nobody holds a copy of it,
so the checks are the same for everyone and cannot be edited into passing.

**You are handed the grader in advance on purpose.** There is no hidden rubric. If a check passes on
your machine it passes in CI, because it is the same script.

---

## Two ways to use it

### 1 · The action — one job per section

The explicit form. Use it when you want to see each section as its own job in the workflow file.

```yaml
# .github/workflows/lab-01.yml
name: lab-01
on:
  push:
    paths: ["lab-01/**"]

jobs:
  section-dockerfile:
    name: "section · dockerfile"
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - uses: kse-ci-cd-basics-course/catshop-grader/verify@v1
        with:
          section: dockerfile
          path: lab-01
```

Repeat the job for each section, changing `section:`. For a bonus section add
`continue-on-error: true` to the job, and it reports without failing the build.

### 2 · The reusable workflow — a whole lab in one call

The short form. One call fans out into the same per-section checks.

```yaml
# .github/workflows/lab-01.yml
name: lab-01
on:
  push:
    paths: ["lab-01/**"]

jobs:
  lab-01:
    uses: kse-ci-cd-basics-course/catshop-grader/.github/workflows/lab.yml@v1
    with:
      path: lab-01
      required: "dockerfile,hardening,compose"
      bonus: "wiremock,networks"
```

Both produce one named check per section. Pick whichever you prefer — **the marks are identical.**

> **Why the workflow file lives at the repository root and not inside `lab-01/`.**
> GitHub only reads workflows from `.github/workflows/` at the root of a repository. A workflow file
> inside a lab folder is never executed. The `paths:` filter is what scopes it to one lab, so
> finishing lab 3 does not re-run lab 1.

---

## Inputs

| Input | Required | Default | Meaning |
|---|---|---|---|
| `section` | yes | — | `dockerfile`, `hardening`, `compose`, `wiremock` or `networks` |
| `path` | no | `.` | the lab folder to grade, e.g. `lab-01` |
| `port` | no | `8080` | the host port the app must be published on |

Outputs: `pass`, `fail`, `warn`, `score`. `fail` is zero when the section is clean.

`fetch-depth: 0` on the checkout is not optional. One check asks whether `.env` has **ever** been
committed, and `actions/checkout` clones one commit by default, which would make that check
meaningless.

---

## The sections

| Section | What it decides | Lab |
|---|---|---|
| `dockerfile` | the image builds, the base is pinned, the cache is ordered, the app answers | 1 · section 1 |
| `hardening` | multi-stage, non-root, no compiler shipped, honest layers | 1 · section 2 |
| `compose` | Compose parses, Postgres is health-gated and unpublished, **the data survives `down`/`up`** | 1 · section 3 |
| `wiremock` | the partner stub answers, and its 500 surfaces as a 502 | 1 · bonus |
| `networks` | networks are explicit, `internal: true` holds, the database has no egress | 1 · bonus |

**Secret checks run in every section**, because a leaked credential is never bonus:

- `.env` is not tracked, and never appears in git history
- `.env` is ignored by git (asked via `git check-ignore`, so any `.gitignore` or `.git/info/exclude` counts)
- no secret-looking value is assigned in the `Dockerfile` — comments are stripped first, so
  documenting *"nothing secret is baked in here"* is not a finding
- no literal password in `compose.yaml`; use `${POSTGRES_PASSWORD}` and `.env`

---

## Running it locally

Students get a wrapper in their own repository:

```bash
./scripts/verify.sh --section dockerfile --path lab-01
```

Or run this repository directly:

```bash
git clone https://github.com/kse-ci-cd-basics-course/catshop-grader
bash catshop-grader/verify/verify.sh --section compose --path lab-01
```

Flags: `--json` for machine-readable output, `--keep` to leave the stack running for inspection,
`--port` to override the expected port. Exit status is zero when nothing failed.

Requires Docker running, Compose v2, and `bash`. On a GitHub `ubuntu-latest` runner all three are
already there.

---

## Reading a result

```
section compose

compose, read
  PASS  compose:valid        compose.yaml parses
  PASS  compose:dbport       the database port is not published
  ...
does the data survive down/up?
  FAIL  persist:volume       the data was LOST across down/up (3 -> 1) — no named
                             volume, or mounted at the wrong path

section compose  17 pass  1 fail  0 warn
```

- **PASS** — done.
- **FAIL** — costs marks. The message names the cause, not just the symptom.
- **WARN** — a judgement call. Not a mark against you, but **explain it in the pull request**; an
  unexplained warning reads as an accident.

In CI the same table is written to the job summary, so you never have to read raw logs to find out
what failed.

---

## For the instructor

Versioning is a moving tag. Students reference `@v1`; fixing a check and re-pointing the tag means
every student gets the fix on their next push, with no action on their part:

```bash
git tag -f v1 && git push -f origin v1
```

Re-point `v1` only for fixes that make the grader *more correct*. A change that makes a previously
passing solution fail mid-lab is a new tag, not a `v1` move.

Both sections of the grader were verified against the reference solutions in
[`catshop-examples`](https://github.com/kse-ci-cd-basics-course/catshop-examples) before release —
17, 16 and 18 checks green respectively, and the no-volume variant correctly fails `persist:volume`.
