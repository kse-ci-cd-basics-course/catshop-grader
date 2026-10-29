#!/usr/bin/env python3
"""Read a student's workflow and report the properties the pipeline section grades.

Kept out of the shell script because the question "can publishing be reached
when the tests are red" is a graph question, and answering it in bash would be
worse than answering it here.
"""
import sys, yaml

path = sys.argv[1]
text = open(path).read()
doc = yaml.safe_load(text) or {}
jobs = doc.get("jobs", {}) or {}


def body(job):
    return yaml.dump(jobs.get(job, {}))


def needs_of(job):
    n = (jobs.get(job) or {}).get("needs") or []
    return [n] if isinstance(n, str) else list(n)


def reaches(frm, to, seen=frozenset()):
    for n in needs_of(frm):
        if n == to:
            return True
        if n not in seen and reaches(n, to, seen | {n}):
            return True
    return False


tests = [j for j in jobs if "pytest" in body(j)]
builds = [j for j in jobs if "docker build" in body(j) or "build-push-action" in body(j)]
pushes = [j for j in jobs
          if "docker push" in body(j)
          or "push: true" in body(j)
          or "push: ${{" in body(j)]

gated = bool(pushes) and bool(tests) and all(
    any(p == t or reaches(p, t) for t in tests) for p in pushes)

print("TESTS", ",".join(tests))
print("BUILDS", ",".join(builds))
print("PUSHES", ",".join(pushes))
print("GATED", "yes" if gated else "no")
print("GHCR", "yes" if "ghcr.io" in text else "no")
print("LATEST", "yes" if ":latest" in text or "latest" in str(doc.get("tags", "")) else "no")
print("REVISION", "yes" if "org.opencontainers.image.revision" in text else "no")
