#!/usr/bin/env bash
# lint-workflow-shell.sh — shellcheck the shell embedded in workflow and action
# YAML, which nothing else looks at.
#
# `run:` blocks are shell scripts that happen to live inside YAML, so no linter
# sees them by default. The blocks here are not trivial: start-runner.yml
# carries most of the repo's trickiest shell -- a retry loop, a case dispatch on
# AWS error strings, functions. That is exactly the kind of code that
# accumulates quoting bugs unnoticed.
#
# Blocks containing `${{ }}` are skipped rather than mangled: GitHub expands
# those before bash ever sees them, and they are not valid shell. Pass values in
# through `env:` instead of interpolating them into the script, and the block
# stays lintable -- which is why every block here does that.
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

command -v shellcheck >/dev/null || {
  echo "shellcheck not on PATH. apt-get install shellcheck, or download a release binary." >&2
  exit 1
}
# Report rather than install. `pip install` mutates the invoking environment and
# hard-fails under PEP 668 on a modern distro, which makes this script awkward to
# run locally -- and local is where a linter earns its keep. PyYAML ships on
# ubuntu-latest, so CI needs nothing.
python3 -c 'import yaml' 2>/dev/null || {
  echo "PyYAML not available. Install it: apt-get install python3-yaml, or pip install pyyaml" >&2
  exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

python3 - "$tmp" <<'PY'
import sys, os, glob, yaml
out = sys.argv[1]
skipped = extracted = 0
files = sorted(glob.glob('.github/workflows/*.yml') + glob.glob('.github/actions/*/action.yml'))
for f in files:
    d = yaml.safe_load(open(f)) or {}
    steps = []
    if 'runs' in d and isinstance(d['runs'], dict):
        steps = d['runs'].get('steps', [])
    for job in (d.get('jobs') or {}).values():
        steps += job.get('steps', []) if isinstance(job, dict) else []
    for i, st in enumerate(steps):
        body = st.get('run') if isinstance(st, dict) else None
        if not body:
            continue
        if '${{' in body:
            print(f"  skip (contains a ${{{{ }}}} expression): {f} :: {st.get('name','step %d' % i)}")
            skipped += 1
            continue
        name = f"{f}.{i}".replace('/', '_').replace('.', '_')
        open(os.path.join(out, name + '.sh'), 'w').write("#!/usr/bin/env bash\n" + body)
        extracted += 1
print(f"  extracted {extracted} run block(s), skipped {skipped}")
# A skipped block is unlinted shell shipping to other repositories' CI, so
# it fails here rather than only in test-boxes.sh. The fix is to pass the
# value in through `env:` instead of interpolating it into the body.
sys.exit(1 if skipped else 0)
PY

shopt -s nullglob
blocks=("$tmp"/*.sh)
# Zero blocks means the extraction silently found nothing -- a moved directory,
# a YAML change -- which must not read as "clean".
(( ${#blocks[@]} )) || { echo "  no run blocks found; extraction is broken" >&2; exit 1; }
shellcheck --severity=style "${blocks[@]}"
echo "  shellcheck clean (severity=style)"
