#!/usr/bin/env bash
# test.sh — checks the shared workflow and actions without touching AWS.
#
# Wherever a step's behaviour is under test, its OWN shell is extracted from the
# YAML and run against stubs, so a test cannot pass by re-implementing the rule.
#
#   ./test.sh
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0; fail=0

ck() { if [[ "$2" == "$3" ]]; then printf '  ok   %-28s %s\n' "$1" "$2"; pass=$((pass+1));
       else printf '  FAIL %-28s got %q want %q\n' "$1" "$2" "$3"; fail=$((fail+1)); fi }

# A refusing `aws` at the front of PATH, so a test that reaches AWS fails
# loudly; the tests that need an answer put their own stub earlier in PATH.
no_aws="$(mktemp -d)"
cat > "$no_aws/aws" <<'NOAWS'
#!/bin/bash
echo "test.sh must not reach AWS: aws $*" >&2
exit 1
NOAWS
chmod +x "$no_aws/aws"
PATH="$no_aws:$PATH"

echo "== check-shared-refs: pinned, and pointing here =="
# The pin check passed vacuously once already: it keyed on an org, the repos
# moved, and no matches reads as "everything is pinned". Run the real thing --
# the whole step, not the pattern alone, because the all-clear is a claim about
# having matched something.
# To the end of the block, not the end of the FILE: `,$p` swept up any step
# added after it and eval'd the YAML as bash.
csr_run=$(sed -n '/^      run: |$/,/^[^ ]/p' "$REPO/.github/actions/check-shared-refs/action.yml" \
          | tail -n +2 | sed -n 's/^        //p')
# `cd || exit 99`, not `cd &&`: a typo'd fixture path otherwise returns 1 and
# makes "matching nothing fails instead of passing" pass for the wrong reason.
csr_out() { ( cd "$1" || exit 99; eval "$csr_run" ) 2>&1; }
csr_rc()  { ( cd "$1" || exit 99; eval "$csr_run" >/dev/null 2>&1 ); echo "$?"; }
csr_fixture() { mkdir -p "$csr_tmp/$1/.github/workflows"; cat > "$csr_tmp/$1/.github/workflows/f.yml"; }

csr_tmp="$(mktemp -d)"
csr_fixture mixed <<'WF'
      - uses: aleo-labs-protocol/gh-actions/.github/actions/x@some-branch
      - uses: "aleo-labs-protocol/gh-actions/.github/actions/y@trial"
      - uses: aleo-labs-protocol/gh-actions/.github/actions/z@v1
WF
ck "the pin check catches an unpinned ref, quoted or not" \
   "$(csr_out "$csr_tmp/mixed" | grep -c 'gh-actions/.github/actions/[xy]@')" "2"
ck "and does not flag a pinned one" \
   "$(csr_out "$csr_tmp/mixed" | grep -c '@v1')" "0"
# The role trusts the workflow only at a tag, so a SHA pin is a denial at STS.
csr_fixture sha <<'WF'
      - uses: aleo-labs-protocol/gh-actions/.github/workflows/start-runner.yml@0123456789abcdef0123456789abcdef01234567
WF
ck "a SHA pin fails here rather than at STS" "$(csr_rc "$csr_tmp/sha")" "1"
# Another org's repo of the same name is not this one, and its refs are theirs.
csr_fixture foreign <<'WF'
      - uses: aleo-labs-protocol/gh-actions/.github/actions/z@v1
      - uses: someone-else/gh-actions/.github/actions/x@main
WF
ck "another org's gh-actions is not held to the pin" "$(csr_rc "$csr_tmp/foreign")" "0"
csr_fixture none <<'WF'
      - uses: actions/checkout@v4
WF
ck "matching nothing fails instead of passing" "$(csr_rc "$csr_tmp/none")" "1"
# What the callers are told to write is the README's own `uses:` examples, so
# the check is run over those rather than over a path retyped here: the day the
# documentation and the pattern stop naming the same repo, this goes red.
grep -ohE 'uses:[[:space:]]*["'"'"']?[A-Za-z0-9._-]+/gh-actions/[^[:space:]]+' "$REPO/README.md" \
  | sed 's/^/      - /' | csr_fixture readme
ck "the refs the README documents are seen, and pinned" "$(csr_rc "$csr_tmp/readme")" "0"
rm -rf "$csr_tmp"
# And they all name ONE repository. Each of those lines is copied into a caller
# repo, and GitHub does not redirect a moved path.
ck "the README documents one repository, not two" \
   "$(grep -ohE 'uses:[[:space:]]*["'"'"']?[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/[.]github/' "$REPO/README.md" \
      | sed -E 's/^uses:[[:space:]]*["'"'"']?//' | awk -F/ '{print $2}' \
      | LC_ALL=C sort -u | tr '\n' ' ')" "gh-actions "


echo "== what callers run is pinned =="
# A shared workflow or action runs with its caller's credentials: the fleet's
# AWS role, an App key. A caller pins this repository at a tag, not what it
# pulls in, so an action used by tag is trusted to whoever can move that tag. A
# SHA cannot be moved; dependabot.yml keeps the pins current. ci.yml is this
# repository's own CI, which no caller runs.
ck "every action the workflows and actions use is pinned to a SHA" \
   "$(find "$REPO/.github/workflows" "$REPO/.github/actions" \( -name '*.yml' -o -name '*.yaml' \) ! -path '*/workflows/ci.yml' -print0 \
      | xargs -0 grep -hoE '^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*[^[:space:]#]+' \
      | sed -E 's/.*uses:[[:space:]]*//' | grep -vE '@[0-9a-f]{40}$' | tr '\n' ' ')" ""

echo "== fleet sizing: this repo's queue, plus the boxes busy elsewhere =="
# The steps' OWN shell, extracted and run against stubs -- not a copy of their
# arithmetic. A test that re-implements the rule passes when the rule changes,
# which is how a swapped guard survived review once already.
fs_tmp="$(mktemp -d)"; mkdir -p "$fs_tmp/bin"
python3 -c "
import yaml
d = yaml.safe_load(open('$REPO/.github/workflows/start-runner.yml'))
st = {x.get('name'): x for x in d['jobs']['start']['steps'] if x.get('name')}
open('$fs_tmp/census.sh', 'w').write(st['Count the boxes already busy']['run'])
open('$fs_tmp/plan.sh', 'w').write(st['Size the fleet to the work']['run'])
"
cat > "$fs_tmp/bin/gh" <<'GHEOF'
#!/bin/bash
[ -n "${GH_FAIL:-}" ] && exit 1
# NAMES, when set, is the literal list of busy runner names to emit; otherwise
# N_TOTAL runners of which the first N_BUSY are busy, named after the fleet.
python3 -c "
import json, os
off = os.environ.get('N_OFFLINE') == '1'
names = os.environ.get('NAMES')
if names:
    for n in names.split():
        print(json.dumps({'name': n, 'labels': [{'name': 'cpu'}],
                          'busy': not off, 'status': ('offline' if off else 'online')}))
else:
    t = int(os.environ['N_TOTAL']); b = int(os.environ['N_BUSY'])
    fleet = os.environ.get('FLEET', '').split()
    for n in range(t):
        print(json.dumps({'name': (fleet[n] if n < len(fleet) else 'cpu-runner%d' % (n + 1)),
                          'labels': [{'name': 'cpu'}],
                          'busy': (False if off else n < b),
                          'status': ('offline' if off else 'online')}))"
GHEOF
chmod +x "$fs_tmp/bin/gh"
census() { # total busy [offline] -> the busy count it reports, empty if it declined to
  : > "$fs_tmp/out"
  PATH="$fs_tmp/bin:$PATH" N_TOTAL="$1" N_BUSY="$2" N_OFFLINE="${3:-0}" GH_TOKEN=x LABEL=cpu ORG=o \
    FLEET="${FLEET:-cpu-runner cpu-runner2 cpu-runner3}" \
    GITHUB_OUTPUT="$fs_tmp/out" bash "$fs_tmp/census.sh" >/dev/null 2>&1
  sed -n 's/^busy=//p' "$fs_tmp/out"
}
census_named() { # literal runner names, all busy -> boxes counted
  : > "$fs_tmp/out"
  PATH="$fs_tmp/bin:$PATH" NAMES="$1" GH_TOKEN=x LABEL=cpu ORG=o \
    FLEET="${FLEET:-cpu-runner cpu-runner2 cpu-runner3}" \
    GITHUB_OUTPUT="$fs_tmp/out" bash "$fs_tmp/census.sh" >/dev/null 2>&1
  sed -n 's/^busy=//p' "$fs_tmp/out"
}
ck "busy boxes are counted"          "$(census 3 2)" "2"
ck "an idle fleet is zero busy"      "$(census 3 0)" "0"
ck "an empty fleet is zero busy"     "$(census 0 0)" "0"
# Registration is persistent and the boxes stop themselves, so a registration
# can outlive its box by 24h. Those are not busy, and counting them as such
# would start a box for work nobody is doing.
ck "a stale offline registration is not busy" "$(census 3 3 1)" "0"
# A 403 or a rate limit parsed as JSON comes back as "no runners" -- which is
# also what an idle fleet looks like. Write nothing rather than write 0, so the
# plan step can tell "nobody is busy" from "could not look".
# BOXES, because the plan step adds this to a count of EC2 instances. A box
# with RUNNER_SLOTS > 1 registers one runner per slot as NAME-1, NAME-2
# (runner-install.sh), so counting registrations makes one busy box read as
# three and takes `want` straight to the fleet cap.
ck "a multi-slot box is one busy box" \
   "$(census_named "cpu-runner-1 cpu-runner-2 cpu-runner-3")" "1"
ck "and slots across two boxes are two" \
   "$(census_named "cpu-runner-1 cpu-runner-2 cpu-runner2-1")" "2"
# A runner elsewhere in the org carrying the same label is not in this fleet,
# and starting our boxes would not relieve whatever it is doing.
ck "a busy runner outside the fleet is not counted" \
   "$(census_named "someone-elses-box")" "0"
ck "and is not counted alongside one that is" \
   "$(census_named "cpu-runner someone-elses-box")" "1"
ck "a failed listing reports nothing, not zero" \
   "$( : > "$fs_tmp/out"; PATH="$fs_tmp/bin:$PATH" GH_FAIL=1 N_TOTAL=3 N_BUSY=3 GH_TOKEN=x LABEL=cpu ORG=o \
       GITHUB_OUTPUT="$fs_tmp/out" bash "$fs_tmp/census.sh" >/dev/null 2>&1; sed -n 's/^busy=//p' "$fs_tmp/out"; echo -n "")" ""

plan() { # queued busy [jobs-per-box] [fleet] -> how many boxes it wants
  : > "$fs_tmp/out"
  FLEET="${4:-cpu-runner cpu-runner2 cpu-runner3}" LABEL=cpu JOBS_PER_BOX="${3:-2}" \
    QUEUED="$1" BUSY="$2" HAVE_CENSUS="$([ -n "$2" ] && echo true || echo false)" \
    GITHUB_OUTPUT="$fs_tmp/out" bash "$fs_tmp/plan.sh" >/dev/null 2>&1
  sed -n 's/^want=//p' "$fs_tmp/out"
}
# Ceiling division, so the last partial box still gets started: 5 jobs at 2 a
# box is 3 boxes, not 2.
ck "the queue is divided, rounding up"  "$(plan 5 0)" "3"
ck "and exactly divides without a spare" "$(plan 4 0)" "2"
# The term that makes the sum right across repositories. Boxes busy with
# another repo's work cannot take ours, so our queue needs capacity ON TOP of
# them -- without this the second repository to arrive sees boxes already up and
# starts nothing while its own jobs wait.
ck "boxes busy elsewhere do not count as ours" "$(plan 3 2)" "3"
ck "and the fleet is still the ceiling"        "$(plan 5 3)" "3"
# The floor. A label nobody offers, a caller that forgot actions:read and a
# rate-limited API all count zero, and a job whose runs-on no runner answers
# queues for 24h before GitHub gives up. Calling this workflow means at least
# one box is wanted.
ck "an empty queue still wants one box"  "$(plan 0 0)" "1"
ck "and so does a queue it could not see" "$(plan '' '')" "1"
# The floor belongs on THIS caller's term, not on the sum. Flooring the sum is
# satisfied by boxes busy with someone else's work: a caller that forgot
# actions:read counts zero, want collapses to busy, every busy box is already
# online, and nothing starts -- so this repo queues behind the other one's jobs
# on exactly the miscount the floor exists to survive.
ck "a queue it could not see still gets a box of its own" "$(plan '' 2)" "3"
# jobs-per-box comes from an input, so it can arrive as anything. Zero divided
# into the queue is a crash, and the step is what stands between a typo and a
# job that never gets a box.
ck "jobs-per-box below one does not divide by zero" "$(plan 5 0 0)" "3"
ck "a one-box fleet is capped at one"    "$(plan 9 0 2 "cpu-runner")" "1"
# The default in the units the fleet was sized in. The busiest caller queues
# five cpu jobs per PR, and cpu-runner3 exists for the days two PRs are in
# flight -- not for every PR, and not never, which is what queue-depth: 6
# against a constant queue of five amounted to.
jpb=$(sed -n '/^      jobs-per-box:/,/type: number/p' "$REPO/.github/workflows/start-runner.yml" | sed -n 's/^ *default: \(.*\)$/\1/p')
ck "one busy PR (5 jobs) wakes two boxes"  "$(plan 5 0 "$jpb")" "2"
ck "two busy PRs (10 jobs) wake the third" "$(plan 10 0 "$jpb")" "3"
rm -rf "$fs_tmp"

# The credential is optional: without it each repository sizes from its own
# queue alone, which is smaller than the truth, never larger.
ck "the census is gated on the token" \
   "$(grep -c "steps.runner-app.outputs.token != ''" "$REPO/.github/workflows/start-runner.yml")" "1"
ck "and cannot fail the job" \
   "$(grep -B 4 "if: steps.runner-app.outputs.token != ''" "$REPO/.github/workflows/start-runner.yml" | grep -c 'continue-on-error: true')" "1"
ck "the token step cannot fail the job either" \
   "$(grep -A 4 'id: runner-app' "$REPO/.github/workflows/start-runner.yml" | grep -c 'continue-on-error: true')" "1"
# Neither can the queue count: a caller that forgot actions:read would otherwise
# get a red run AND no box, where the floor alone would have given it a box.
ck "the queue count cannot fail the job" \
   "$(grep -A 6 'id: queue' "$REPO/.github/workflows/start-runner.yml" | grep -c 'continue-on-error: true')" "1"
# The AWS steps carry NO `if`. A gate in front of them is exactly the shape of
# the bug that made the overflow box start MORE often than before: a condition
# assembled from counts that turned out to be constant, skipping the only step
# that calls StartInstances while the job stayed green. The floor in the plan
# step is what decides "at least one box" now, and it is arithmetic, not a gate.
ck "nothing gates the AWS steps" \
   "$(python3 -c "
import yaml
d = yaml.safe_load(open('$REPO/.github/workflows/start-runner.yml'))
st = d['jobs']['start']['steps']
aws = [x for x in st if 'configure-aws-credentials' in str(x.get('uses', '')) or x.get('name') in ('Find the fleet', 'Start what the fleet is short')]
print(len(aws), sum(1 for x in aws if 'if' in x))")" "3 0"
# `secrets` is not a context a step-level `if` can read: the expression fails to
# compile and takes down every caller.
ck "the secret is not read in a step if" \
   "$(grep -cE "^ *if: .*secrets\." "$REPO/.github/workflows/start-runner.yml")" "0"
ck "it is hoisted to job-level env" \
   "$(grep -c 'HAS_RUNNER_APP_KEY: ' "$REPO/.github/workflows/start-runner.yml")" "1"

echo "== shared workflow and actions are wired for other repos =="
# These are consumed by other repositories. A rename or a dropped input breaks
# their CI, not this repo's, so it is worth pinning here.
WF="$REPO/.github/workflows/start-runner.yml"
ck "reusable workflow exists" "$([[ -f "$WF" ]] && echo yes || echo no)" "yes"
ck "is callable"              "$(grep -c 'workflow_call:' "$WF")" "1"
# role-to-assume is an INPUT rather than read from `vars` inside the reusable
# workflow: it decides which AWS role is assumed, and how `vars` resolves for a
# called workflow is not something to leave to inference. Asserted against the
# parsed YAML, not by counting the string -- it also appears in a comment and at
# its use site, so a text count pins the wrong thing and breaks on a reworded
# comment.
ck "declares role-to-assume input" \
   "$(python3 -c "
import yaml
d = yaml.safe_load(open('$WF'))
on = d.get('on', d.get(True))
i = on['workflow_call']['inputs']
print('yes' if i.get('role-to-assume', {}).get('required') else 'no')
" 2>/dev/null)" "yes"
for a in gpu-runner-preflight gpu-runner-report runner-job-setup check-shared-refs; do
  ck "$a action exists" "$([[ -f "$REPO/.github/actions/$a/action.yml" ]] && echo yes || echo no)" "yes"
  ck "$a is composite"  "$(grep -c 'using: composite' "$REPO/.github/actions/$a/action.yml")" "1"
done
# The two preflights protect different things now, deliberately: job-setup
# protects the target dir it just named, which on a one-slot box is shared by
# every job of the repository and lives outside the work root; gpu-test keeps
# its target beside the checkout, so gpu-runner-preflight protects the work
# root and covers it. What must stay aligned is the guard path and the
# missing-guard error, so those are pinned rather than the whole step.
ck "job setup falls back to a dir per job without it" \
   "$(grep -cF 'target="${RUNNER_WORKSPACE}/${TARGET_NAME}-target"' "$REPO/.github/actions/runner-job-setup/action.yml")" "1"
ck "and shares one dir per repo with it" \
   "$(grep -cF 'target="${CI_TARGET_ROOT}/${GITHUB_REPOSITORY/\//-}"' "$REPO/.github/actions/runner-job-setup/action.yml")" "1"
# The guard finds build dirs by CACHEDIR.TAG, and cargo writes it only when it
# creates the dir itself -- which mkdir -p prevents. Untagged means invisible to
# the cap, to sweep and to escalate.
ck "job setup tags the target dir for the guard" \
   "$(grep -c "CACHEDIR.TAG" "$REPO/.github/actions/runner-job-setup/action.yml")" "2"
ck "job setup protects the dir it is about to fill" \
   "$(grep -cF 'preflight "${CARGO_TARGET_DIR}"' "$REPO/.github/actions/runner-job-setup/action.yml")" "1"
ck "the GPU preflight protects its work root" \
   "$(grep -cF 'preflight "${RUNNER_WORKSPACE}"' "$REPO/.github/actions/gpu-runner-preflight/action.yml")" "1"
ck "both take the same guard path" \
   "$(python3 -c "
import yaml
def g(n): return yaml.safe_load(open('$REPO/.github/actions/'+n+'/action.yml'))['inputs']['disk-guard']
print('same' if g('gpu-runner-preflight') == g('runner-job-setup') else 'DIFFER')
")" "same"
ck "both refuse a box with no guard" \
   "$(grep -lF 'is missing or not executable' "$REPO/.github/actions/gpu-runner-preflight/action.yml" \
      "$REPO/.github/actions/runner-job-setup/action.yml" | wc -l | tr -d ' ')" "2"
# Inert on a hosted runner: every step is gated on the box.
ck "job setup gates every step on the box" \
   "$(f="$REPO/.github/actions/runner-job-setup/action.yml"; [[ $(grep -c "if: runner.environment == 'self-hosted'" "$f") == $(grep -c '^    - name:' "$f") ]] && echo yes || echo no)" "yes"
ck "job setup takes the box's rustup lock" "$(grep -c 'flock /tmp/rustup.lock cargo --version' "$REPO/.github/actions/runner-job-setup/action.yml")" "1"

# The sccache four, re-asserted through GITHUB_ENV (issue #58). Run rather than
# grepped, because what matters is which names come out and where they come
# FROM: the box's file, not the step's own environment, which a job-level `env:`
# has already reached. Only the source path is rewritten -- so a step that read
# anything else would fall through to this machine's real /etc/environment and
# fail the first check below.
sc_env_tmp="$(mktemp -d)"
python3 -c "
import yaml
d = yaml.safe_load(open('$REPO/.github/actions/runner-job-setup/action.yml'))
st = [s for s in d['runs']['steps'] if s.get('name') == 'sccache environment'][0]
open('$sc_env_tmp/sccache.sh','w').write(st['run'].replace('/etc/environment','$sc_env_tmp/environment'))
"
sccache_env() { # /etc/environment contents -> the lines that reach GITHUB_ENV
  printf '%s\n' "$1" > "$sc_env_tmp/environment"; : > "$sc_env_tmp/github_env"
  # The process environment a job-level `env:` block would have left behind.
  RUSTC_WRAPPER="" CARGO_INCREMENTAL=1 SCCACHE_DIR=/tmp/elsewhere SCCACHE_CACHE_SIZE=1G \
    GITHUB_ENV="$sc_env_tmp/github_env" bash "$sc_env_tmp/sccache.sh" >/dev/null
  tr '\n' '|' < "$sc_env_tmp/github_env"
}
ck "re-asserted from the box, not the override" \
   "$(sccache_env 'PATH="/usr/local/sbin:/usr/bin"
CUDA_HOME="/usr/local/cuda"
RUSTC_WRAPPER=/usr/local/bin/sccache
CARGO_INCREMENTAL=0
SCCACHE_DIR=/var/cache/sccache
SCCACHE_CACHE_SIZE=60G')" \
   "RUSTC_WRAPPER=/usr/local/bin/sccache|CARGO_INCREMENTAL=0|SCCACHE_DIR=/var/cache/sccache|SCCACHE_CACHE_SIZE=60G|"
# `SCCACHE_DIR=` empty turns sccache off, and bootstrap.sh then leaves none of
# the four in /etc/environment. Inventing a value here would point RUSTC_WRAPPER
# at a binary the box never installed and break every build on it.
ck "a box with sccache off re-asserts nothing" \
   "$(sccache_env 'PATH="/usr/bin"
CUDA_HOME="/usr/local/cuda"')" \
   ""
# /etc/environment is conventionally quoted, and GITHUB_ENV is not: a wrapper
# arriving as "/usr/local/bin/sccache" names a path that does not exist.
ck "quotes are stripped on the way through" \
   "$(sccache_env 'RUSTC_WRAPPER="/usr/local/bin/sccache"')" \
   "RUSTC_WRAPPER=/usr/local/bin/sccache|"
# A box provisioned outside bootstrap.sh has no such file. Every job on it
# should build slowly, not fail at setup -- refusing an unprovisioned box is the
# disk preflight's job, and it says why.
rm -f "$sc_env_tmp/environment"; : > "$sc_env_tmp/github_env"
ck "no environment file is not a job failure" \
   "$(GITHUB_ENV="$sc_env_tmp/github_env" bash "$sc_env_tmp/sccache.sh" >/dev/null 2>&1 \
      && echo "rc=0 $(cat "$sc_env_tmp/github_env")")" "rc=0 "
rm -rf "$sc_env_tmp"
# The fleet input has to reach the DESCRIBE FILTER, not just the error message.
# The tag it replaced shipped plumbed into `env:` and into the failure text while
# the query stayed hardcoded, so a caller overriding it searched for the wrong
# instance and was told it could not find the one it never looked for. A linter
# cannot see that: the variable IS used, just not where it matters.
ck "fleet input reaches the query" \
   "$(grep -c 'Values=$(IFS=,; echo "${boxes\[\*\]}")' "$WF")" "1"
ck "the fleet is not hardcoded in the query" \
   "$(grep -c 'Values=gpu-runner' "$WF")" "0"

# The fork guard must reject pull_request_target, which is the trigger its own
# comment names. `github.event_name != 'pull_request'` is TRUE for
# pull_request_target, so an `||` guard short-circuits and the job runs -- on the
# one trigger where the token is writable and the secrets are present.
ck "guard rejects pull_request_target" \
   "$(grep -c "event_name != 'pull_request_target'" "$WF")" "2"

# Values reach these scripts through `env:`, never interpolated into the body.
# That is what keeps them lintable -- a `${{ }}` inside a run block is not valid
# shell, so lint-workflow-shell.sh has to skip any block containing one.
#
# Asserted on POSITIVE evidence, not on the absence of a skip line. `grep -c` on
# empty input prints 0, so comparing a skip count to "0" also passes when the
# linter exited early and printed nothing at all -- which it does when shellcheck
# is missing or PyYAML is unavailable. Both were reachable.
lint_out="$(PATH="${SHELLCHECK_DIR:-/usr/bin}:$PATH" "$REPO/lint-workflow-shell.sh" 2>&1)"
lint_rc=$?
ck "linter succeeds"        "$lint_rc" "0"
ck "run blocks extracted"   "$(grep -c 'extracted [1-9]' <<<"$lint_out")" "1"
ck "no \${{ }} in run bodies" "$(grep -c 'skip (contains' <<<"$lint_out")" "0"

echo "== start-runner: capacity-fallback chain =="
# Extracted from the real workflow YAML rather than hand-copied, so this cannot
# drift from what actually ships. The chain has been rewritten three times in a
# day -- immutable OIDC subjects, the capacity retry, a fallback whose target had
# silently become its own source, and the g6f.xlarge tier -- and it is consumed
# by two other repositories' CI with real AWS credentials. shellcheck cannot see
# any of these bugs; only running the branches can.
#
# CAPACITY_RETRY_SECONDS=0 keeps this instant rather than mocking `sleep`: the
# deadline is checked after each round, so exactly one round runs and one
# scripted CAP costs exactly one shape.
SCR="$REPO/.github/workflows/start-runner.yml"
sc_tmp="$(mktemp -d)"; mkdir -p "$sc_tmp/bin"
python3 -c "
import yaml
d = yaml.safe_load(open('$SCR'))
steps = {s.get('name'): s for s in d['jobs']['start']['steps'] if s.get('name')}
open('$sc_tmp/start.sh', 'w').write(steps['Start what the fleet is short']['run'])
open('$sc_tmp/queue.sh', 'w').write(steps['Measure the queue']['run'])
"
cat > "$sc_tmp/bin/aws" <<'AWSEOF'
#!/usr/bin/env bash
# Mock aws CLI. State lives in files, since each invocation is a new process.
case "$1 $2" in
  # LADDER is the CapacityLadder tag of every box the inventory does not give
  # one, so a test names the ladder once rather than per box.
  "ec2 describe-instances") printf '%s\n' "$*" > "${CNT}.describe"; awk -v l="${LADDER:-}" 'BEGIN { FS = OFS = "\t" } NF == 5 { $6 = l } 1' "$INV" ;;
  "ec2 start-instances")
    id=""; prev=""
    for a in "$@"; do [[ "$prev" == "--instance-ids" ]] && id="$a"; prev="$a"; done
    n=$(( $(cat "$CNT.$id" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$CNT.$id"
    # FAIL_<id, hyphens as underscores> scripts one box; FAIL_SEQ scripts them all.
    v="FAIL_${id//-/_}"; IFS=',' read -ra seq <<< "${!v:-${FAIL_SEQ:-OK}}"
    case "${seq[$((n-1))]:-OK}" in
      OK)    exit 0 ;;
      DENY)  echo "An error occurred (UnauthorizedOperation)" >&2; exit 1 ;;
      CAP)   echo "An error occurred (InsufficientInstanceCapacity)" >&2; exit 1 ;;
      STATE) echo "An error occurred (IncorrectInstanceState)" >&2; exit 1 ;;
      QUOTA) echo "An error occurred (VcpuLimitExceeded)" >&2; exit 1 ;;
    esac ;;
  "ec2 wait") echo "$*" >> "${CNT}.wait"; exit 0 ;;
  "ec2 modify-instance-attribute") ;;
esac
AWSEOF
chmod +x "$sc_tmp/bin/aws"

# One line per box, exactly as `describe-instances --output text` prints the
# query: Name tag, id, type, state, PreferredInstanceType, and the stub adds
# CapacityLadder. "None" is what it
# really prints for a tag that is not there -- a box provisioned before
# that tag was written, which the chain still has to handle.
box() { printf '%s\ti-%s\t%s\t%s\t%s\n' "$1" "$1" "$2" "${3:-stopped}" "${4:-None}"; }

fleet_start() { # runs the real step over whatever $sc_tmp/inv holds
  rm -f "$sc_tmp"/cnt.*
  PATH="$sc_tmp/bin:$PATH" INV="$sc_tmp/inv" CNT="$sc_tmp/cnt" \
  FLEET="${FLEET:-gpu-runner}" LABEL="${LABEL:-gpu}" WANT="${WANT:-1}" \
  LADDER="${LADDER:-g6.4xlarge g6.2xlarge g6.xlarge g6e.xlarge}" \
  CAPACITY_RETRY_SECONDS=0 RETRY_SLEEP_SECONDS=0 \
  bash "$sc_tmp/start.sh" 2>&1 | grep -E "^started |^::(warning|error|notice)::" | tr '\n' '|'
}
start_chain() { # initial_type  fail_seq  -- one box, so this is the ladder alone
  if [ -n "${MISSING_TAG:-}" ]; then : > "$sc_tmp/inv"
  else box "${TAG:-gpu-runner}" "$1" stopped "${PREFERRED_TAG:-None}" > "$sc_tmp/inv"; fi
  FLEET="${TAG:-gpu-runner}" LABEL="${LABEL:-gpu}" FAIL_SEQ="$2" fleet_start
}
start_rc() { start_chain "$@" >/dev/null; echo "${PIPESTATUS[0]}"; }

ck "a stopped box is started" \
   "$(start_chain g6.xlarge OK)" \
   "started gpu-runner as g6.xlarge|"
ck "g6 exhausted -> g6e succeeds" \
   "$(start_chain g6.xlarge CAP,OK)" \
   "started gpu-runner as g6e.xlarge|::warning::gpu-runner started as g6e.xlarge instead of its configured g6.xlarge: no capacity for it in its AZ|"
# Four boxes, a quota for two: the rest are refused by the quota, which is said
# plainly and costs the box, never a walk down the ladder.
rm -f "$sc_tmp"/cnt.*
box gpu-runner g6.4xlarge running g6.4xlarge > "$sc_tmp/inv"
box gpu-runner2 g6.4xlarge running g6.4xlarge >> "$sc_tmp/inv"
box gpu-runner3 g6.4xlarge stopped g6.4xlarge >> "$sc_tmp/inv"
ck "a start past the quota is skipped" \
   "$(WANT=3 FLEET="gpu-runner gpu-runner2 gpu-runner3" LABEL=gpu FAIL_SEQ=QUOTA fleet_start)" \
   "::warning::starting i-gpu-runner3 would exceed the account's vCPU quota; skipping it|::warning::wanted 3 gpu boxes, have 2; the queue will drain slower|"
# Nothing left to try: loud and specific, never a silent hang.
ck "g6 and g6e exhausted -> named error" \
   "$(start_chain g6.xlarge CAP,CAP)" \
   "::warning::could not start i-gpu-runner as any of its shapes (tried: g6.xlarge g6e.xlarge)|::error::no box carrying gpu is online and none could be started; jobs needing it queue for 24h before GitHub gives up|"
# A box an older ladder left on g6f cannot run the suite: it
# is retyped off it, and g6f is never tried, tagged or not.
ck "box already g6f: retyped to g6.xlarge" \
   "$(start_chain g6f.xlarge OK)" \
   "::warning::this box is currently g6f.xlarge, a fractional L4 that cannot run the CUDA suite; retyping it to a full-size shape|started gpu-runner as g6.xlarge|"
ck "box already g6f: never falls back to it" \
   "$(PREFERRED_TAG=g6f.xlarge start_chain g6f.xlarge CAP,CAP | tr '|' '\n' | tail -n 2 | head -n 1)" \
   "::warning::could not start i-gpu-runner as any of its shapes (tried: g6.xlarge g6e.xlarge)"
# A permission error is not a capacity error. Returning "this tier is full" for
# an UnauthorizedOperation walked the box down its entire ladder, retyping it at
# every step and blaming capacity for each -- three misleading warnings and a
# box left on a shape nobody chose.
ck "denied: one message, no retyping" \
   "$(start_chain g6.4xlarge DENY,DENY,DENY,DENY,DENY)" \
   "::warning::An error occurred (UnauthorizedOperation)|::error::no box carrying gpu is online and none could be started; jobs needing it queue for 24h before GitHub gives up|"

echo "== start-runner: reconciling the fleet to what the queue needs =="
# There is no primary box and no overflow box: a fleet is a list, WANT says how
# many of it should be up, and this step starts the difference. The old
# primary/overflow split is what made "the second box failed" and "no box at
# all" the same code path with a boolean between them.
three() { box cpu-runner c6i.8xlarge "${1:-stopped}" c6i.8xlarge
          box cpu-runner2 c6i.8xlarge "${2:-stopped}" None
          box cpu-runner3 c6i.8xlarge "${3:-stopped}" None; }
cpu_fleet() { FLEET="cpu-runner cpu-runner2 cpu-runner3" LABEL=cpu \
              LADDER="c6i.8xlarge c6a.8xlarge m6i.8xlarge" fleet_start; }

three > "$sc_tmp/inv"
ck "wants two of three, starts two" "$(WANT=2 cpu_fleet)" \
   "started cpu-runner as c6i.8xlarge|started cpu-runner2 as c6i.8xlarge|"
# In fleet order, so concurrent runs make the same choice and the box that gets
# the most use is the one whose sccache and target dir are warmest.
ck "and takes them in fleet order"  "$(WANT=1 cpu_fleet)" \
   "started cpu-runner as c6i.8xlarge|"
three running > "$sc_tmp/inv"
ck "a box already up counts, and is not restarted" "$(WANT=2 cpu_fleet)" \
   "started cpu-runner2 as c6i.8xlarge|"
ck "a fleet already big enough starts nothing"     "$(WANT=1 cpu_fleet)" ""
# pending is a box someone else's run started seconds ago. Counting it as
# offline is how two concurrent runs start two boxes for one queue.
three pending > "$sc_tmp/inv"
ck "a box mid-boot counts as online"               "$(WANT=1 cpu_fleet)" ""
# The failure that used to need a boolean: one box refusing is not the run's
# problem as long as another takes its place.
three > "$sc_tmp/inv"
ck "a box that refuses hands off to the next" \
   "$(WANT=1 FAIL_i_cpu_runner=DENY cpu_fleet)" \
   "::warning::An error occurred (UnauthorizedOperation)|started cpu-runner2 as c6i.8xlarge|"
ck "and that is not an error" "$(WANT=1 FAIL_i_cpu_runner=DENY cpu_fleet >/dev/null; echo "${PIPESTATUS[0]}")" "0"
# Only an EMPTY fleet is an error, because only then does a job queue for 24h.
ck "no box startable at all is the error" \
   "$(WANT=1 FAIL_SEQ=DENY cpu_fleet | tr '|' '\n' | tail -n 1)" \
   "::error::no box carrying cpu is online and none could be started; jobs needing it queue for 24h before GitHub gives up"
# Short of what was wanted, with something up, is a slower queue and nothing
# worse -- said out loud, since the alternative is a run that looks fine while
# the fleet quietly never grows.
ck "short of the target, with a box up, warns" \
   "$(three running > "$sc_tmp/inv"; WANT=3 FAIL_SEQ=DENY cpu_fleet | tr '|' '\n' | tail -n 1)" \
   "::warning::wanted 3 cpu boxes, have 1; the queue will drain slower"
# A box in the fleet that nobody has provisioned yet is a notice, not a
# failure: the fleet list is where a box is added, and provisioning it is a
# separate step that may not have happened.
ck "an unprovisioned box is a notice" \
   "$(box cpu-runner c6i.8xlarge running c6i.8xlarge > "$sc_tmp/inv"; WANT=2 cpu_fleet)" \
   "::notice::no instance tagged cpu-runner2; that box is not provisioned (ROLE=cpu2 ./provision.sh)|::notice::no instance tagged cpu-runner3; that box is not provisioned (ROLE=cpu3 ./provision.sh)|::warning::wanted 2 cpu boxes, have 1; the queue will drain slower|"
# Two instances wearing one Name tag is a provisioning mistake, and starting
# either is a guess. Skipped and said, rather than head -1.
ck "an ambiguous tag is left alone" \
   "$(box cpu-runner c6i.8xlarge running c6i.8xlarge > "$sc_tmp/inv"
      box cpu-runner2 c6i.8xlarge >> "$sc_tmp/inv"; box cpu-runner2 c6a.8xlarge >> "$sc_tmp/inv"
      WANT=2 FLEET="cpu-runner cpu-runner2" LABEL=cpu fleet_start | tr '|' '\n' | head -n 1)" \
   "::warning::expected one instance tagged cpu-runner2, found 2; leaving it alone"

# --output text prints "None" for a missing tag, but an EMPTY tag value prints
# an empty field. Splitting the candidate on spaces then left $4 unbound, and
# `set -u` killed the step with a bare bash error: no ::error:: annotation, no
# box started, and a red job naming a line number in a file nobody can open.
ck "a box with an empty preferred tag still starts" \
   "$(printf 'cpu-runner\ti-cpu-runner\tc6i.8xlarge\tstopped\t\n' > "$sc_tmp/inv"
      WANT=1 FLEET="cpu-runner" LABEL=cpu LADDER="c6i.8xlarge" fleet_start)" \
   "started cpu-runner as c6i.8xlarge|"

# Patience is for the box the caller is BLOCKED on, and for no other. Every job
# in the calling repo carries `needs:` on this workflow, so a second box waiting
# out a dry AZ holds jobs that a box already online could have run -- up to the
# whole ladder budget. The split the old layout got from running the overflow
# start as a separate job alongside gpu-test.
# The budget is 5s, not 1: a budget near the stub's own fork latency makes this
# pass or fail on machine load.
patience_run() { # inv is already written; -> how many times it waited
  PATH="$sc_tmp/bin:$PATH" INV="$sc_tmp/inv" CNT="$sc_tmp/cnt" \
  FLEET="$1" LABEL=cpu WANT="$2" LADDER="c6i.8xlarge" \
  CAPACITY_RETRY_SECONDS=5 RETRY_SLEEP_SECONDS=0 \
  FAIL_SEQ="$3" \
  bash "$sc_tmp/start.sh" 2>&1 | grep -c "again in"
}
rm -f "$sc_tmp"/cnt.*
box cpu-runner c6i.8xlarge > "$sc_tmp/inv"
ck "the box nothing is online for waits out a refusal" \
   "$([ "$(patience_run "cpu-runner" 1 CAP,OK)" -ge 1 ] && echo waited || echo "did not")" "waited"
rm -f "$sc_tmp"/cnt.*
box cpu-runner c6i.8xlarge running > "$sc_tmp/inv"; box cpu-runner2 c6i.8xlarge >> "$sc_tmp/inv"
ck "a box added for throughput does not" \
   "$(patience_run "cpu-runner cpu-runner2" 2 CAP,OK)" "0"

# A box added for throughput does not walk the ladder at all. It gets one try,
# so a single momentary capacity answer would retype it down every shape in
# milliseconds and strand it on its smallest. The box the caller IS blocked on
# still walks the whole ladder.
rm -f "$sc_tmp"/cnt.*
box gpu-runner g6.4xlarge running g6.4xlarge > "$sc_tmp/inv"
box gpu-runner2 g6.xlarge stopped g6.xlarge >> "$sc_tmp/inv"
ck "a box nothing waits for is not retyped for capacity" \
   "$(WANT=2 FLEET="gpu-runner gpu-runner2" LABEL=gpu FAIL_i_gpu_runner2=CAP,CAP,OK fleet_start)" \
   "::warning::no g6.xlarge capacity for gpu-runner2; leaving it on its configured shape rather than retyping a box nothing is waiting for|::warning::wanted 2 gpu boxes, have 1; the queue will drain slower|"
rm -f "$sc_tmp"/cnt.*
ck "and the box that is waited for still walks its ladder" \
   "$(TAG=gpu-runner start_chain g6.xlarge CAP,OK)" \
   "started gpu-runner as g6e.xlarge|::warning::gpu-runner started as g6e.xlarge instead of its configured g6.xlarge: no capacity for it in its AZ|"

# Every AZ is asked before any box steps down. The old layout walked the first
# box's whole ladder before asking the second box once, so on 2026-09-29 the
# second AZ waited 27 minutes to be asked at all.
rm -f "$sc_tmp"/cnt.*
box gpu-runner g6.4xlarge stopped g6.4xlarge > "$sc_tmp/inv"
box gpu-runner2 g6.4xlarge stopped g6.4xlarge >> "$sc_tmp/inv"
ck "the second AZ is asked before the first box steps down" \
   "$(WANT=1 FLEET="gpu-runner gpu-runner2" LABEL=gpu FAIL_i_gpu_runner=CAP,CAP,CAP,CAP fleet_start)$(cat "$sc_tmp/cnt.i-gpu-runner")" \
   "started gpu-runner2 as g6.4xlarge|::warning::no g6.4xlarge capacity for gpu-runner; leaving it on its configured shape rather than retyping a box nothing is waiting for|1"
# And every round starts back at the widest shape: capacity for it may have
# returned while the narrower ones were being asked.
rm -f "$sc_tmp"/cnt.*
box gpu-runner g6.4xlarge stopped g6.4xlarge > "$sc_tmp/inv"
ck "a new round starts back at the widest shape" \
   "$(PATH="$sc_tmp/bin:$PATH" INV="$sc_tmp/inv" CNT="$sc_tmp/cnt" FLEET=gpu-runner LABEL=gpu WANT=1 \
      LADDER="g6.4xlarge g6.2xlarge" CAPACITY_RETRY_SECONDS=5 RETRY_SLEEP_SECONDS=0 \
      FAIL_SEQ=CAP,CAP,OK bash "$sc_tmp/start.sh" 2>&1 | grep -E "^started ")" \
   "started gpu-runner as g6.4xlarge"

# A box caught mid-stop ends the round at its shape: it is one sleep from
# starting at full size, so the others must not step down past it meanwhile.
rm -f "$sc_tmp"/cnt.*
box gpu-runner g6.4xlarge stopping g6.4xlarge > "$sc_tmp/inv"
box gpu-runner2 g6.4xlarge stopped g6.4xlarge >> "$sc_tmp/inv"
ck "a mid-stop box keeps the others from stepping down past it" \
   "$(PATH="$sc_tmp/bin:$PATH" INV="$sc_tmp/inv" CNT="$sc_tmp/cnt" FLEET="gpu-runner gpu-runner2" LABEL=gpu WANT=1 \
      LADDER="g6.4xlarge g6.2xlarge" CAPACITY_RETRY_SECONDS=5 RETRY_SLEEP_SECONDS=0 \
      FAIL_i_gpu_runner=STATE,OK FAIL_i_gpu_runner2=CAP,OK bash "$sc_tmp/start.sh" 2>&1 | grep -E "^started ")" \
   "started gpu-runner as g6.4xlarge"
# A box retyped down and then passed over, because another started later in
# the same round, is said to be left there -- not "on its configured shape".
rm -f "$sc_tmp"/cnt.*
box gpu-runner g6.4xlarge stopped g6.4xlarge > "$sc_tmp/inv"
box gpu-runner2 g6.4xlarge stopped g6.4xlarge >> "$sc_tmp/inv"
ck "a box left on a narrower shape says so" \
   "$(WANT=1 FLEET="gpu-runner gpu-runner2" LABEL=gpu FAIL_i_gpu_runner=CAP,CAP FAIL_i_gpu_runner2=CAP,OK fleet_start | tr '|' '\n' | grep 'gpu-runner down')" \
   "::warning::no capacity for gpu-runner down to g6.2xlarge; it is left stopped as g6.2xlarge, and the next run retypes it back to g6.4xlarge"
# No box provisioned at all is the named error, not bash tripping over an empty
# array under -u (bash before 4.4).
ck "an empty fleet is the named error" \
   "$(: > "$sc_tmp/inv"; FLEET=gpu-runner fleet_start | tr '|' '\n' | tail -n 1)" \
   "::error::no box carrying gpu is online and none could be started; jobs needing it queue for 24h before GitHub gives up"

# The ladder only ever steps DOWN. A box sitting ABOVE its configured shape --
# a manual bump, or a provision predating the tag -- had that shape appended to
# the tail of the chain by the line meant to handle OFF-ladder boxes, so
# exhausting the configured tiers retyped it back UP, taking vCPUs the other box
# in the fleet is sized for. That is the growth the tag exists to prevent.
rm -f "$sc_tmp"/cnt.*
box gpu-runner2 g6.2xlarge stopped g6.xlarge > "$sc_tmp/inv"
ck "a box above its tag is never retyped back up" \
   "$(WANT=1 FLEET=gpu-runner2 LABEL=gpu FAIL_SEQ=CAP,CAP,CAP,CAP fleet_start | tr '|' '\n' | tail -n 2 | head -n 1)" \
   "::warning::could not start i-gpu-runner2 as any of its shapes (tried: g6.xlarge g6e.xlarge)"
# And an off-ladder box is still tried as itself, which is what that line is for.
rm -f "$sc_tmp"/cnt.*
ck "an off-ladder box is still tried as itself" \
   "$(TAG=cpu-runner LABEL=cpu start_chain c6i.8xlarge CAP | tr '|' '\n' | tail -n 2 | head -n 1)" \
   "::warning::could not start i-cpu-runner as any of its shapes (tried: c6i.8xlarge)"

# `wait instance-stopped` polls 40 x 15s, so on a box that is NOT stopping it
# blocks the full 600s and then fails, with `|| true` hiding that it never
# converged -- ten minutes of a job every caller is blocked on, to reach a
# retype that cannot succeed. Only a box the inventory found mid-stop is worth
# waiting for.
rm -f "$sc_tmp"/cnt.*
box gpu-runner g6.xlarge stopped g6.4xlarge > "$sc_tmp/inv"
ck "a stopped box is not waited for before a retype" \
   "$(WANT=1 FLEET=gpu-runner LABEL=gpu fleet_start >/dev/null; wc -l < "$sc_tmp/cnt.wait" 2>/dev/null || echo 0)" "0"
rm -f "$sc_tmp"/cnt.*
box gpu-runner g6.xlarge stopping g6.4xlarge > "$sc_tmp/inv"
ck "a stopping box is" \
   "$(WANT=1 FLEET=gpu-runner LABEL=gpu fleet_start >/dev/null; [ -s "$sc_tmp/cnt.wait" ] && echo waited || echo "did not")" "waited"

# The mid-stop retry has to throttle on EVERY path. `|| sleep 20` braked only
# when the waiter FAILED, and the reachable case is the waiter SUCCEEDING:
# describe reads `stopped` while StartInstances still answers
# IncorrectInstanceState, so the loop spun -- 67 calls in two seconds against
# this stub, ~20,000 inside the default 600s budget, from one job. EC2 answers
# that with RequestLimitExceeded, which matches no arm here.
rm -f "$sc_tmp"/cnt.*
box cpu-runner c6i.8xlarge stopped c6i.8xlarge > "$sc_tmp/inv"
# The one test that must NOT turn the sleep off -- the throttle is what it
# measures -- so it turns it down instead and shortens its window to match.
state_calls=$(timeout 2 env PATH="$sc_tmp/bin:$PATH" INV="$sc_tmp/inv" CNT="$sc_tmp/cnt" \
  FLEET=cpu-runner LABEL=cpu WANT=1 LADDER="c6i.8xlarge" \
  CAPACITY_RETRY_SECONDS=600 RETRY_SLEEP_SECONDS=1 \
  FAIL_i_cpu_runner="$(python3 -c "print(','.join(['STATE']*5000))")" \
  bash "$sc_tmp/start.sh" >/dev/null 2>&1; cat "$sc_tmp/cnt.i-cpu-runner" 2>/dev/null || echo 0)
ck "a mid-stop retry is throttled, not spun" \
   "$([ "${state_calls:-0}" -le 3 ] && echo throttled || echo "spun:${state_calls}")" "throttled"

# A box caught mid-shutdown is the ROUTINE state here -- the boxes stop
# themselves -- and it is not a shape problem: no type it could be retyped to
# would start either. Returning "this tier is full" sent it down the ladder,
# retyping at every step, blaming capacity in every message, and landing it on
# its last-resort shape.
rm -f "$sc_tmp"/cnt.*
box cpu-runner c6i.8xlarge running c6i.8xlarge > "$sc_tmp/inv"
box cpu-runner2 c6i.8xlarge stopping c6i.8xlarge >> "$sc_tmp/inv"
ck "a box mid-shutdown is left alone, not retyped" \
   "$(WANT=2 FLEET="cpu-runner cpu-runner2" LABEL=cpu LADDER="c6i.8xlarge c6a.8xlarge m6i.8xlarge" \
      FAIL_i_cpu_runner2=STATE,STATE,OK fleet_start)" \
   "::warning::i-cpu-runner2 is still stopping; leaving it for the next run rather than retyping it|::warning::wanted 2 cpu boxes, have 1; the queue will drain slower|"
# And the box the fleet actually depends on is asked again next round, by
# which time the instance has reached `stopped` and the start works.
rm -f "$sc_tmp"/cnt.*
box cpu-runner c6i.8xlarge stopping c6i.8xlarge > "$sc_tmp/inv"
ck "the box the fleet depends on waits for the stop to finish" \
   "$(PATH="$sc_tmp/bin:$PATH" INV="$sc_tmp/inv" CNT="$sc_tmp/cnt" FLEET=cpu-runner LABEL=cpu WANT=1 \
      LADDER="c6i.8xlarge c6a.8xlarge" CAPACITY_RETRY_SECONDS=5 \
      RETRY_SLEEP_SECONDS=0 \
      FAIL_i_cpu_runner=STATE,OK bash "$sc_tmp/start.sh" 2>&1 | grep -E "^started |^::" | tr '\n' '|')" \
   "started cpu-runner as c6i.8xlarge|"

# Anchored: `ROLE=` also matches inside `CUDA_ROLE=`, so the unanchored version
# these started as stayed green against the name the #110 rename removed.
# The provision hint has to name a role lib.sh accepts: <class>-runner<n> is the
# role <class><n>. Stripping "-runner" alone left a third box as "cpu-runner3",
# and the notice named a command that errors.
ck "provision hint names the role for gpu-runner" \
   "$(MISSING_TAG=gpu-runner TAG=gpu-runner start_chain g6.4xlarge OK | grep -oE '\bROLE=[a-z0-9]+')" "ROLE=gpu"
ck "provision hint names the role for gpu-runner2" \
   "$(MISSING_TAG=gpu-runner2 TAG=gpu-runner2 start_chain g6.xlarge OK | grep -oE '\bROLE=[a-z0-9]+')" "ROLE=gpu2"
ck "provision hint names the role for cpu-runner" \
   "$(MISSING_TAG=cpu-runner TAG=cpu-runner LABEL=cpu start_chain c6i.8xlarge OK | grep -oE '\bROLE=[a-z0-9]+')" "ROLE=cpu"
ck "provision hint names the role for cpu-runner3" \
   "$(MISSING_TAG=cpu-runner3 TAG=cpu-runner3 LABEL=cpu start_chain c6i.8xlarge OK | grep -oE '\bROLE=[a-z0-9]+')" "ROLE=cpu3"

# A CPU box brings its own ladder: none of the Ada shapes, and its current
# shape is still tried first.
ck "cpu ladder: current first, then its own shapes" \
   "$(TAG=cpu-runner LABEL=cpu LADDER="c6i.8xlarge c6a.8xlarge m6i.8xlarge" start_chain c6i.8xlarge CAP,OK)" \
   "started cpu-runner as c6a.8xlarge|::warning::cpu-runner started as c6a.8xlarge instead of its configured c6i.8xlarge: no capacity for it in its AZ|"
# Started without its own ladder, a CPU box is off the Ada one: it is tried as
# it is and nothing else. The alternative walked the whole GPU ladder.
ck "off-ladder box: itself only, and says so" \
   "$(TAG=cpu-runner LABEL=cpu start_chain c6i.8xlarge CAP | tr '|' '\n' | head -n 1)" \
   "::warning::c6i.8xlarge is not on the ladder (g6.4xlarge g6.2xlarge g6.xlarge g6e.xlarge); no capacity fallback for this box"
ck "cpu ladder exhausted never reaches a GPU shape" \
   "$(TAG=cpu-runner LABEL=cpu LADDER="c6i.8xlarge c6a.8xlarge" start_chain c6i.8xlarge CAP,CAP | tr '|' '\n' | head -n 1)" \
   "::warning::could not start i-cpu-runner as any of its shapes (tried: c6i.8xlarge c6a.8xlarge)"
ck "a one-box fleet that cannot start exits 1" "$(start_rc g6.xlarge CAP,CAP,CAP)" "1"
ck "and so does one that is refused"           "$(start_rc g6.xlarge DENY)" "1"

# The ratchet. A box degraded by a past outage used to have no way back: the
# chain began at CURRENT, so g6.xlarge was both where it started and the best it
# would ever try. gpu-runner ran at a quarter of its configured size on this
# path. The PreferredInstanceType tag provision.sh writes is what breaks it.
ck "degraded box climbs back to its tag" \
   "$(PREFERRED_TAG=g6.4xlarge start_chain g6.xlarge OK)" \
   "::notice::i-gpu-runner is g6.xlarge but is configured for g6.4xlarge; a past capacity shortfall left it there. Trying g6.4xlarge first.|started gpu-runner as g6.4xlarge|"
# Down the ladder one size at a time, not straight to the bottom: a 4xlarge slot
# is harder to find than a 2xlarge, and the job wants the most cores it can get.
ck "steps down a size at a time" \
   "$(PREFERRED_TAG=g6.4xlarge start_chain g6.4xlarge CAP,OK)" \
   "started gpu-runner as g6.2xlarge|::warning::gpu-runner started as g6.2xlarge instead of its configured g6.4xlarge: no capacity for it in its AZ|"
ck "exhausts the ladder in order" \
   "$(PREFERRED_TAG=g6.4xlarge start_chain g6.4xlarge CAP,CAP,CAP,CAP,CAP | tr '|' '\n' | tail -n 2 | head -n 1)" \
   "::warning::could not start i-gpu-runner as any of its shapes (tried: g6.4xlarge g6.2xlarge g6.xlarge g6e.xlarge)"
# The other half of the rule: a box configured as an xlarge is an xlarge on
# purpose, and must never grow into another box's share of the quota on a
# capacity retry.
ck "a small box never grows past its tag" \
   "$(PREFERRED_TAG=g6.xlarge TAG=gpu-runner2 start_chain g6.xlarge CAP,CAP,CAP | tr '|' '\n' | tail -n 2 | head -n 1)" \
   "::warning::could not start i-gpu-runner2 as any of its shapes (tried: g6.xlarge g6e.xlarge)"
# An untagged box -- one from outside this repo, since provision.sh tags every
# box it starts -- walks the ladder down from wherever it is and nowhere else.
# With the ladder an input, the old fixed Ada tail is gone: it would have sent a
# CPU box to a g6.
ck "untagged box: down its ladder from where it is" \
   "$(start_chain g6e.xlarge CAP,CAP | tr '|' '\n' | tail -n 2 | head -n 1)" \
   "::warning::could not start i-gpu-runner as any of its shapes (tried: g6e.xlarge)"

# The ladder is each box's own CapacityLadder tag ("None" when it has none), so one fleet can hold boxes
# with different ladders and none is walked down another's.
ck "each box walks its own ladder tag" \
   "$(printf 'cpu-runner\ti-cpu-runner\tc6i.8xlarge\tstopped\tc6i.8xlarge\tc6i.8xlarge c6a.8xlarge\n' > "$sc_tmp/inv"
      WANT=1 FLEET=cpu-runner LABEL=cpu FAIL_SEQ=CAP,OK fleet_start | tr '|' '\n' | head -n 1)" \
   "started cpu-runner as c6a.8xlarge"
ck "a box with no ladder tag is tried as itself, and says so" \
   "$(box cpu-runner c6i.8xlarge > "$sc_tmp/inv"; WANT=1 FLEET=cpu-runner LABEL=cpu LADDER=None FAIL_SEQ=CAP fleet_start | tr '|' '\n' | head -n 2 | tr '\n' '|')" \
   "::warning::i-cpu-runner has no CapacityLadder tag; no capacity fallback for it|::warning::could not start i-cpu-runner as any of its shapes (tried: c6i.8xlarge)|"
# Tab is IFS whitespace, so splitting on it collapses an empty field: an empty
# PreferredInstanceType tag would hand the ladder to `preferred`.
ck "an empty preferred tag does not swallow the ladder" \
   "$(printf 'cpu-runner\ti-cpu-runner\tc6i.8xlarge\tstopped\t\tc6i.8xlarge c6a.8xlarge\n' > "$sc_tmp/inv"
      WANT=1 FLEET=cpu-runner LABEL=cpu FAIL_SEQ=CAP,OK fleet_start | tr '|' '\n' | head -n 1)" \
   "started cpu-runner as c6a.8xlarge"

# The stub prints the columns whatever the query asks for, so the query itself
# is pinned: the ladder is read from the sixth column, and a box with the Name
# but not the label is not in the fleet.
box cpu-runner c6i.8xlarge > "$sc_tmp/inv"; WANT=1 FLEET=cpu-runner LABEL=cpu fleet_start >/dev/null
ck "the inventory asks for the ladder after the preferred shape" \
   "$(grep -c "Tags\[?Key=='PreferredInstanceType'\]|\[0\].Value,Tags\[?Key=='CapacityLadder'\]|\[0\].Value\]" "$sc_tmp/cnt.describe")" "1"
ck "and only for boxes carrying the label" \
   "$(grep -c -- 'Name=tag:RunnerLabel,Values=cpu ' "$sc_tmp/cnt.describe")" "1"

echo "== start-runner: the fleet is found by its label tag =="
ff_tmp="$(mktemp -d)"; mkdir -p "$ff_tmp/bin"
python3 -c "
import yaml
d = yaml.safe_load(open('$SCR'))
steps = {s.get('name'): s for s in d['jobs']['start']['steps'] if s.get('name')}
open('$ff_tmp/find.sh', 'w').write(steps['Find the fleet']['run'])
"
cat > "$ff_tmp/bin/aws" <<'AWSEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$ARGS"
[ -z "${AWS_FAIL:-}" ] || exit 1
printf '%b' "${NAMES:-}"
AWSEOF
chmod +x "$ff_tmp/bin/aws"
find_fleet() { # NAMES as --output text prints them -> the fleet output and the step's exit code
  : > "$ff_tmp/out"
  local rc=0
  PATH="$ff_tmp/bin:$PATH" ARGS="$ff_tmp/args" LABEL=cpu GITHUB_OUTPUT="$ff_tmp/out" \
    bash "$ff_tmp/find.sh" >/dev/null 2>&1 || rc=$?
  printf '%s|%s' "$(sed -n 's/^fleet=//p' "$ff_tmp/out")" "$rc"
}
# In name order whatever order EC2 answers in, so concurrent runs wake the same
# box first, and version order so a tenth box is not second.
ck "the fleet is the tagged boxes, in name order" \
   "$(NAMES='cpu-runner10\tcpu-runner2\ncpu-runner\n' find_fleet)" "cpu-runner cpu-runner2 cpu-runner10|0"
ck "found by the label it was called with" \
   "$(grep -c -- 'Name=tag:RunnerLabel,Values=cpu ' "$ff_tmp/args")" "1"
ck "and named by the Name tag" \
   "$(grep -c -- "--query Reservations\[\].Instances\[\].Tags\[?Key=='Name'\].Value" "$ff_tmp/args")" "1"
ck "a label no box carries is an error, not an empty fleet" \
   "$(NAMES='' find_fleet | cut -d'|' -f2)" "1"
ck "and says which tag it looked for" \
   "$(PATH="$ff_tmp/bin:$PATH" ARGS="$ff_tmp/args" NAMES='' LABEL=cpu GITHUB_OUTPUT=/dev/null bash "$ff_tmp/find.sh" 2>&1 | grep -c '^::error::no box is tagged RunnerLabel=cpu')" "1"
ck "a describe that fails is an error" \
   "$(PATH="$ff_tmp/bin:$PATH" ARGS="$ff_tmp/args" AWS_FAIL=1 LABEL=cpu GITHUB_OUTPUT=/dev/null bash "$ff_tmp/find.sh" 2>&1 | grep -c '^::error::could not describe the cpu fleet')" "1"

echo "== start-runner: the queue this repository can see =="
# Only jobs still waiting for a runner with the label count: a queued job on
# ubuntu-latest is GitHub's backlog, not ours, and an in_progress gpu-test
# already has a box. Runs are listed under BOTH statuses, because the calling
# run is in_progress while its own gpu-test sits queued behind `needs`.
cat > "$sc_tmp/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
# Mock `gh api --paginate URL --jq`. QUEUED_RUNS / RUNNING_RUNS list run ids;
# JOBS_<id> holds each run's jobs as "status:label,label ..." entries, emitted
# as the stream the real --jq '.jobs[]' produces.
[[ -n "${GH_FAIL:-}" ]] && { echo "gh: HTTP 403" >&2; exit 1; }
# The URL is whichever argument starts with a slash: --paginate shifts it.
url=""; for a in "$@"; do [[ "$a" == /* ]] && { url="$a"; break; }; done
case "$url" in
  */actions/workflows/*/runs*) [[ -n "${HIST_FAIL:-}" ]] && exit 1; for r in ${PREV_RUNS:-}; do echo "$r"; done ;;
  *"runs?status=queued"*)      [[ -n "${RUNS_FAIL:-}" ]] && exit 1
                               for r in $QUEUED_RUNS;  do p="PATH_$r"; echo "$r ${!p:-.github/workflows/other.yml}"; done ;;
  *"runs?status=in_progress"*) [[ -n "${RUNS_FAIL:-}" ]] && exit 1
                               for r in $RUNNING_RUNS; do p="PATH_$r"; echo "$r ${!p:-.github/workflows/other.yml}"; done ;;
  */jobs*)
    id="${url#*/runs/}"; id="${id%%/*}"
    var="JOBS_${id}"
    for j in ${!var}; do
      printf '{"status":"%s","labels":["%s"]}\n' "${j%%:*}" "$(printf '%s' "${j#*:}" | sed 's/,/","/g')"
    done ;;
esac
GHEOF
chmod +x "$sc_tmp/bin/gh"

queue() { # -> the two count lines, then what it handed the plan step
  : > "$sc_tmp/out"
  PATH="$sc_tmp/bin:$PATH" GITHUB_REPOSITORY=o/r GITHUB_OUTPUT="$sc_tmp/out" LABEL=cuda \
  GITHUB_RUN_ID=3 GITHUB_WORKFLOW_REF="${WF_REF:-o/r/.github/workflows/ci.yml@refs/heads/main}" \
  PREV_RUNS="${PREV_RUNS-9 8}" \
  JOBS_9="completed:self-hosted,linux,x64,cuda,sm_89 failure:self-hosted,cuda skipped:ubuntu-latest" \
  JOBS_8="completed:ubuntu-latest" \
  QUEUED_RUNS="1 2" RUNNING_RUNS="3 ${QUEUED_RUNS_EXTRA:-} ${EXTRA_RUN:-}" \
  JOBS_1="completed:ubuntu-latest queued:self-hosted,linux,x64,cuda,sm_89" \
  JOBS_2="queued:ubuntu-latest queued:self-hosted,cuda" \
  JOBS_3="in_progress:ubuntu-latest queued:self-hosted,cuda in_progress:self-hosted,cuda" \
  JOBS_4="in_progress:ubuntu-latest" PATH_4="${PATH_4:-.github/workflows/ci.yml}" \
  bash "$sc_tmp/queue.sh" 2>&1 | grep -E '^cuda jobs|^queued cuda' | tr '\n' '|'; cat "$sc_tmp/out"
}
# THIS run's jobs do not exist yet and will not until this workflow finishes:
# they carry `needs:` on it, so GitHub has not created them. Counting the API
# alone returns 0 for the caller that is asking, every time -- measured on a
# caller that released five cpu jobs and reported `queued cpu jobs: 0`. The old
# three-caller layout hid it, because the overflow callers ran with `needs:` on
# the primary and counted after the jobs were real.
#
# So the run's own demand comes from what this workflow released on recent runs
# -- job records, any conclusion, so a matrix counts by its legs.
ck "counts what this workflow releases, and excludes this run" "$(queue)" \
   "cuda jobs this workflow releases per run: 2|queued cuda jobs in other o/r runs: 2|queued=4"
# The LARGEST of several completed runs, not the newest. Run 8 is a run
# cancelled while its start job was still going: only the ubuntu-latest start
# job on record, because nothing behind `needs` was ever created. A fork PR
# looks identical, since the guard skips the start job too. Reading the newest
# alone reports 0 for those and falls back to the floor -- the same silent
# undersizing, by a different route.
ck "a cancelled run in the history does not drag it to zero" "$(PREV_RUNS="8 9" queue)" \
   "cuda jobs this workflow releases per run: 2|queued cuda jobs in other o/r runs: 2|queued=4"
# Two pushes landing together is the case the fleet most needs to absorb, and
# it is the one case the queue cannot see: run 4's label jobs are behind its own
# start job's `needs`, exactly as this run's are. Without crediting it, both
# runs size for one run's demand and both ask for the same two boxes.
ck "a concurrent run of this workflow counts as another run's worth" \
   "$(EXTRA_RUN=4 queue)" \
   "cuda jobs this workflow releases per run: 2|queued cuda jobs in other o/r runs: 4|queued=6"
# Only for THIS workflow, whose demand we know. Another workflow with no label
# jobs on record may simply not have any.
# A git ref may contain @ (only `@{` is forbidden). `%@*` cuts at the LAST one,
# leaving an @-fragment on wf_path so it matches no run's .path -- silently
# turning off the crediting above, which is the whole of what keeps two pushes
# landing together from each sizing for one run's demand.
ck "a ref containing @ still credits a sibling run" \
   "$(EXTRA_RUN=4 WF_REF="o/r/.github/workflows/ci.yml@refs/tags/v1@rc" queue)" \
   "cuda jobs this workflow releases per run: 2|queued cuda jobs in other o/r runs: 4|queued=6"
ck "a concurrent run of a different workflow does not" \
   "$(EXTRA_RUN=4 PATH_4=.github/workflows/other.yml queue)" \
   "cuda jobs this workflow releases per run: 2|queued cuda jobs in other o/r runs: 2|queued=4"
# The two listings are separate API calls, so a run that is `queued` during the
# first and `in_progress` during the second appears in both. Counted twice it
# over-provisions -- and for a sibling run of this workflow it adds a whole
# `own` worth twice.
ck "a run in both listings is counted once" "$(QUEUED_RUNS_EXTRA=1 queue)" \
   "cuda jobs this workflow releases per run: 2|queued cuda jobs in other o/r runs: 2|queued=4"
ck "a workflow with no completed runs has no history to size by" "$(PREV_RUNS='' queue)" \
   "cuda jobs this workflow releases per run: 0|queued cuda jobs in other o/r runs: 2|queued=2"
# "0 because nothing has completed" and "0 because the listing was refused"
# print the same line, and the second is a regression hiding as the first.
ck "a refused history listing says so" \
   "$(: > "$sc_tmp/out"
      PATH="$sc_tmp/bin:$PATH" HIST_FAIL=1 GITHUB_REPOSITORY=o/r GITHUB_OUTPUT="$sc_tmp/out" LABEL=cuda \
      GITHUB_RUN_ID=3 GITHUB_WORKFLOW_REF="o/r/.github/workflows/ci.yml@refs/heads/main" \
      QUEUED_RUNS="" RUNNING_RUNS="" \
      bash "$sc_tmp/queue.sh" 2>&1 | grep -c "::warning::could not read this workflow.s history")" "1"
# A listing that fails -- 403 without actions:read, a rate limit mid-burst --
# must not read as an empty queue. `for x in $(cmd)` hides cmd's status from
# set -e, which is how it did.
#
# It also must not fail the job. A caller that forgot actions:read would get a
# red run AND no box, where writing nothing gets it the floor of one box and a
# warning naming the permission -- the degradation the count is allowed to have.
qfail() { PATH="$sc_tmp/bin:$PATH" GH_FAIL=1 GITHUB_REPOSITORY=o/r GITHUB_OUTPUT="$sc_tmp/out" LABEL=cuda \
          GITHUB_RUN_ID=3 GITHUB_WORKFLOW_REF="o/r/.github/workflows/ci.yml@refs/heads/main" \
          bash "$sc_tmp/queue.sh" 2>&1; }
# The demand already measured survives the failure. `own` is often the whole of
# this run's need, and discarding it for one flaky listing hands a deep queue
# the floor of one box -- the same undersizing, reached by a different route.
ck "a failed listing keeps the demand already measured" \
   "$( : > "$sc_tmp/out"
       PATH="$sc_tmp/bin:$PATH" RUNS_FAIL=1 GITHUB_REPOSITORY=o/r GITHUB_OUTPUT="$sc_tmp/out" LABEL=cuda \
       GITHUB_RUN_ID=3 GITHUB_WORKFLOW_REF="o/r/.github/workflows/ci.yml@refs/heads/main" \
       PREV_RUNS="9 8" JOBS_9="completed:self-hosted,cuda failure:self-hosted,cuda" JOBS_8="completed:ubuntu-latest" \
       bash "$sc_tmp/queue.sh" >/dev/null 2>&1; sed -n 's/^queued=//p' "$sc_tmp/out")" "2"
ck "and names the permission it wanted" \
   "$(qfail | grep -c '^::warning::could not list .*actions: read')" "1"
ck "and the step is marked so that cannot redden the run" \
   "$(grep -A 6 'id: queue' "$REPO/.github/workflows/start-runner.yml" | grep -c 'continue-on-error: true')" "1"
rm -rf "$sc_tmp"

echo "== gpu-runner-preflight: which GPU it decides it landed on =="
# Extracted from the action YAML for the same reason the chain above is: this
# step is consumed by two other repositories, and its whole job is to classify a
# string nobody here can see until a job lands on unfamiliar hardware.
#
# It failed the one case it existed for. On a g6f the driver cannot bind the
# vGPU, nvidia-smi exits 9, and the step reported "Process completed with exit
# code 9" and nothing else -- because nvidia-smi prints its explanation to
# STDOUT, straight into a command substitution that was never echoed. Finding
# that took an EC2 console-log dump (#10). Mocking nvidia-smi is the only way to
# run these branches without the hardware.
PF="$REPO/.github/actions/gpu-runner-preflight/action.yml"
pf_tmp="$(mktemp -d)"; mkdir -p "$pf_tmp/bin"
python3 -c "
import yaml
d = yaml.safe_load(open('$PF'))
st = [s for s in d['runs']['steps'] if s.get('name') == 'Which GPU actually ran'][0]
open('$pf_tmp/gpu.sh', 'w').write(st['run'])
"
cat > "$pf_tmp/bin/nvidia-smi" <<'SMIEOF'
#!/usr/bin/env bash
# Mock nvidia-smi. SMI_OUT is what it prints, SMI_RC what it exits with.
# Printing to STDOUT even when failing is not an oversight -- it is exactly what
# the real one does, and the reason the old code swallowed the message.
printf '%s\n' "$SMI_OUT"
exit "${SMI_RC:-0}"
SMIEOF
chmod +x "$pf_tmp/bin/nvidia-smi"

which_gpu() { # smi_output  smi_rc -> annotations, joined; plus the exit code
  SMI_OUT="$1" SMI_RC="${2:-0}" EXPECTED_GPU=L4 \
  GITHUB_STEP_SUMMARY="$pf_tmp/summary" PATH="$pf_tmp/bin:$PATH" \
  bash "$pf_tmp/gpu.sh" 2>&1 | grep -E "^::(warning|error)::" | tr '\n' '|'
}

# A whole L4: the deployment card itself, so nothing to say.
ck "full L4 passes quietly" \
   "$(which_gpu 'NVIDIA L4, 8.9, 23034 MiB')" \
   ""
# The trailing comma is what keeps this from matching "L4," inside "L40S," --
# an L40S has roughly twice the memory, so a test that would exhaust the
# deployment card passes on one and proves less than it appears to.
ck "L40S still warns (the comma matters)" \
   "$(which_gpu 'NVIDIA L40S, 8.9, 46068 MiB')" \
   "::warning::ran on NVIDIA L40S, 8.9, 46068 MiB, not the L4 this code deploys to — different GPU memory, so a failure that depends on the deployment card's limits would not reproduce here|"
# A g6f reports a PROFILE name. It matched neither arm before, so it fell to the
# L40S branch and claimed the box might be more capable than the deployment
# card -- the exact opposite of a slice with an eighth of the memory.
ck "vGPU slice gets its own warning" \
   "$(which_gpu 'NVIDIA L4-3Q, 8.9, 3072 MiB')" \
   "::warning::ran on NVIDIA L4-3Q, 8.9, 3072 MiB — a vGPU SLICE of the L4, not a whole one. Same sm_89, but a fraction of the memory and time-sliced SMs shared with other tenants: a pass here is a correctness result, not a timing one|"
# The regression this section exists for: a driver that did not load must say so.
ck "driver failure names itself, not just exit 9" \
   "$(which_gpu "NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver." 9)" \
   "::error::nvidia-smi failed with exit 9; this box has no usable GPU.|::error::Exit 9 is NVML's \"driver not loaded\". On a full-size shape that is usually a kernel update the DKMS modules were not rebuilt for; on a g6f, which only the GRID driver binds, it is expected.|"
# And it must still FAIL. Reporting the reason is worthless if the job goes
# green on a box with no GPU.
SMI_OUT="NVIDIA-SMI has failed" SMI_RC=9 EXPECTED_GPU=L4 \
  GITHUB_STEP_SUMMARY="$pf_tmp/summary" PATH="$pf_tmp/bin:$PATH" \
  bash "$pf_tmp/gpu.sh" >/dev/null 2>&1
ck "driver failure still fails the step" "$?" "9"

echo "== merge-branches: which sources need a run =="
mb_tmp="$(mktemp -d)"; mkdir -p "$mb_tmp/bin-check" "$mb_tmp/bin"
python3 -c "
import yaml
d = yaml.safe_load(open('$REPO/.github/workflows/merge-branches.yml'))
st = {x.get('name'): x for j in d['jobs'].values() for x in j['steps'] if x.get('name')}
open('$mb_tmp/check.sh', 'w').write(st['Find the sources with commits to merge']['run'])
"
# Both stubs answer `pr list` with JSON run through the step's own --jq, so the
# step's filtering is what is tested.
cat > "$mb_tmp/jq_arg" <<'JQEOF'
jq_arg() { local prev=; for a in "$@"; do [ "$prev" = --jq ] && { echo "$a"; return; }; prev=$a; done; }
JQEOF
# AHEAD_<src> is how far the source is ahead of the target ("fail" fails the
# call), OPEN_<src> and FORK_<src> how many pull requests from this repository
# and from forks are open from its branch, MISSING_<src> how many of the
# source's commits that branch lacks.
cat > "$mb_tmp/bin-check/gh" <<'GHEOF'
#!/bin/bash
. "$MB_JQ_ARG"
case "$*" in
  *"compare/$TARGET..."*) v="AHEAD_${2##*...}"
    [ "${!v}" = fail ] && { echo '{"message":"Not Found"}'; exit 1; }
    echo "${!v}";;
  *"pr list"*) h="$*"; h="${h#*--head ci/merge-}"; o="OPEN_${h%%-into-*}"; f="FORK_${h%%-into-*}"
    jq -n --argjson o "${!o:-0}" --argjson f "${!f:-0}" \
      '[range($f) | {isCrossRepository: true}] + [range($o) | {isCrossRepository: false}]' \
      | jq -r "$(jq_arg "$@")";;
  *compare/ci/merge-*) s="${2#*compare/ci/merge-}"; v="MISSING_${s%%-into-*}"; echo "${!v}";;
  *) echo "unexpected: gh $*" >&2; exit 1;;
esac
GHEOF
chmod +x "$mb_tmp/bin-check/gh"
mb_check() { # env assignments -> the pending sources, then " rc=N" if the step failed
  : > "$mb_tmp/out"
  env "$@" PATH="$mb_tmp/bin-check:$PATH" MB_JQ_ARG="$mb_tmp/jq_arg" REPO=o/r TARGET=staging \
    GITHUB_OUTPUT="$mb_tmp/out" bash "$mb_tmp/check.sh" >/dev/null 2>&1
  local rc=$?
  printf '%s' "$(sed -n 's/^pending=//p' "$mb_tmp/out" | jq -c '[.[].source]')"
  [ "$rc" = 0 ] || printf ' rc=%s' "$rc"
}
ck "nothing ahead, nothing to run" \
   "$(mb_check SOURCES='testnet mainnet' AHEAD_testnet=0 AHEAD_mainnet=0)" '[]'
ck "ahead with no pull request" \
   "$(mb_check SOURCES='testnet mainnet' AHEAD_testnet=3 AHEAD_mainnet=0)" '["testnet"]'
ck "an open pull request carries it" \
   "$(mb_check SOURCES='testnet' AHEAD_testnet=3 OPEN_testnet=1 MISSING_testnet=0)" '[]'
ck "the source moved past it" \
   "$(mb_check SOURCES='testnet' AHEAD_testnet=4 OPEN_testnet=1 MISSING_testnet=1)" '["testnet"]'
ck "both sources, in order" \
   "$(mb_check SOURCES='testnet mainnet' AHEAD_testnet=1 AHEAD_mainnet=2)" '["testnet","mainnet"]'
ck "each names the branch it merges into" \
   "$(mb_check SOURCES='testnet' AHEAD_testnet=1 >/dev/null; sed -n 's/^pending=//p' "$mb_tmp/out")" \
   '[{"source":"testnet","branch":"ci/merge-testnet-into-staging"}]'
ck "a fork's pull request is not ours" \
   "$(mb_check SOURCES='testnet' AHEAD_testnet=3 FORK_testnet=1 MISSING_testnet=0)" '["testnet"]'
ck "one source failing skips only it" \
   "$(mb_check SOURCES='testnet mainnet' AHEAD_testnet=fail AHEAD_mainnet=2)" '["mainnet"] rc=1'
ck "a source that is the target fails" \
   "$(mb_check SOURCES='staging' AHEAD_staging=0)" ' rc=1'

echo "== merge-branches: merging, conflicts and reviewers =="
# A real git remote, so the merge, the push and what the branch ends up holding
# are git's own answers. Commit subjects stand in for the API: `pr:N:login` is
# a commit from merged pull request N by login, `direct:login` one with none.
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$mb_tmp/gitconfig"
git config -f "$GIT_CONFIG_GLOBAL" user.name test
git config -f "$GIT_CONFIG_GLOBAL" user.email test@example.com
git config -f "$GIT_CONFIG_GLOBAL" init.defaultBranch staging
git config -f "$GIT_CONFIG_GLOBAL" advice.detachedHead false
git init -q --bare "$mb_tmp/origin.git"
# Logs pushes into the same log as the gh stub, so their order is checked.
printf '#!/bin/sh\necho push >> %q\n' "$mb_tmp/log" > "$mb_tmp/origin.git/hooks/pre-receive"
chmod +x "$mb_tmp/origin.git/hooks/pre-receive"
cat > "$mb_tmp/bin/gh" <<'GHEOF'
#!/bin/bash
[ "${GH_TOKEN:-}" = tok-SECRET ] || { echo "gh without the app token: gh $*" >&2; exit 1; }
. "$MB_JQ_ARG"
args="$*"
lookup_fail() { [ -n "${MB_LOOKUP_FAIL:-}" ] && { echo '{"message":"Bad credentials"}'; exit 1; }; }
case "$*" in
  "pr list"*) [ -n "${MB_ON_PR_LIST:-}" ] && bash "$MB_ON_PR_LIST" >/dev/null 2>&1
    jq -n --arg o "$MB_PR" --arg f "${MB_FORK_PR:-}" \
      '[($f | select(. != "") | {number: tonumber, isCrossRepository: true}),
        ($o | select(. != "") | {number: tonumber, isCrossRepository: false})]' \
      | jq -r "$(jq_arg "$@")";;
  "api users/"*) echo 12345;;
  *"/commits/"*"/pulls "*) lookup_fail; s=${args#*/commits/}; s=$(git log -1 --format=%s "${s%%/*}")
    [[ $s == pr:* ]] && { s=${s#pr:}; echo "${s%%:*} ${s#*:}"; };;
  *"/commits/"*) lookup_fail; s=${args#*/commits/}; s=$(git log -1 --format=%s "${s%% *}")
    [[ $s == direct:* ]] && echo "${s#direct:}";;
  *"/pulls/7/reviews"*) lookup_fail; printf 'bob\nalice\nrenovate[bot]\n';;
  *"/pulls/14/reviews"*) lookup_fail; seq -f 'r%02g' 20;;
  *"/reviews"*) lookup_fail; echo frank;;
  *requested_reviewers*|"label create"*|"pr comment"*|"pr edit"*|"pr ready"*) echo "gh $*" >> "$MB_LOG";;
  "pr create"*) echo "gh $*" >> "$MB_LOG"; echo https://github.com/o/r/pull/42;;
  *) echo "unexpected: gh $*" >&2; exit 1;;
esac
GHEOF
chmod +x "$mb_tmp/bin/gh"

git init -q "$mb_tmp/seed"
mb_git() { git -C "$mb_tmp/seed" "$@"; }
mb_commit() { # branch subject file content ("-" deletes the file)
  mb_git checkout -q "$1"
  if [ "$4" = - ]; then mb_git rm -q "$3"; else echo "$4" > "$mb_tmp/seed/$3"; mb_git add "$3"; fi
  mb_git commit -q -m "$2"
  mb_git push -q origin "$1"
}
mb_git remote add origin "$mb_tmp/origin.git"
echo 1 > "$mb_tmp/seed/a"; echo 1 > "$mb_tmp/seed/c"
mb_git add a c; mb_git commit -q -m base
mb_git branch testnet; mb_git branch mainnet
mb_git push -q origin staging testnet mainnet
mb_commit staging "staging edits c" c 2
mb_commit testnet "pr:7:alice" a 2
mb_commit testnet "direct:carol" b 1
mb_commit mainnet "pr:9:dave" c -

# The merge job's steps, each run as the runner would: only if its `if:` holds,
# and with the env its YAML gives it. The app token is tok-SECRET, so a step
# or script that can see it is caught.
cat > "$mb_tmp/step.py" <<'PYEOF'
import re, sys, yaml
wf, name, outputs, script, *inputs = sys.argv[1:]
d = yaml.safe_load(open(wf))
st = next(x for x in d['jobs']['merge']['steps'] if x.get('name') == name)
inputs = dict(i.split('=', 1) for i in inputs)
outs = dict(l.rstrip('\n').split('=', 1) for l in open(outputs) if '=' in l)
def ref(r):
    r = r.strip()
    if r == 'steps.app.outputs.token': return 'tok-SECRET'
    if r == 'steps.app.outputs.app-slug': return 'merge-bot'
    if r.startswith('steps.merge.outputs.'): return outs.get(r[len('steps.merge.outputs.'):], '')
    if r.startswith('inputs.'): return inputs.get(r[len('inputs.'):], '')
    sys.exit('unknown expression: ' + r)
def holds(c):
    for part in c.split('&&'):
        m = re.fullmatch(r"\s*(\S+)\s*(==|!=)\s*'([^']*)'\s*", part)
        if not m: sys.exit('unknown condition: ' + part)
        if (ref(m[1]) == m[3]) != (m[2] == '=='): return False
    return True
print('run' if 'if' not in st or holds(st['if']) else 'skip')
for k, v in (st.get('env') or {}).items():
    print(k + '=' + re.sub(r'\$\{\{(.*?)\}\}', lambda m: ref(m[1]), str(v)))
open(script, 'w').write(st['run'])
PYEOF
mb_wf="$REPO/.github/workflows/merge-branches.yml"
mb_step() { # step name -> its exit code; skipped when its condition is false
  local e rc
  mapfile -t e < <(python3 "$mb_tmp/step.py" "$mb_wf" "$1" "$mb_tmp/outputs" "$mb_tmp/step.sh" ${MB_POST_MERGE:+"post-merge=$MB_POST_MERGE"})
  case "${e[0]:-}" in run) ;; skip) return 0;; *) echo "step.py failed for $1"; return 98;; esac
  ( cd "$mb_tmp/work" || exit 99
    env "${e[@]:1}" PATH="$mb_tmp/bin:$PATH" MB_LOG="$mb_tmp/log" MB_PR="$MB_PR" MB_JQ_ARG="$mb_tmp/jq_arg" REPO=o/r \
      TARGET=staging SOURCE="$MB_SOURCE" BRANCH="ci/merge-$MB_SOURCE-into-staging" \
      GITHUB_SERVER_URL=https://github.com GITHUB_RUN_ID=1 GITHUB_WORKFLOW=w \
      RUNNER_TEMP="$mb_tmp/runner" GITHUB_OUTPUT="$mb_tmp/outputs" bash "$mb_tmp/step.sh" )
}
mb_run() { # source  open-pr-number-or-empty -> the job's exit code
  rm -rf "$mb_tmp/work" "$mb_tmp/runner"
  git clone -q --branch staging "$mb_tmp/origin.git" "$mb_tmp/work"
  mkdir "$mb_tmp/runner"
  : > "$mb_tmp/log"; : > "$mb_tmp/outputs"
  local MB_SOURCE=$1 MB_PR=$2
  { mb_step "Merge the source without committing" &&
    mb_step "Run the post-merge script" &&
    mb_step "Commit, push, and open or update the pull request"; } > "$mb_tmp/out" 2>&1
  echo "$?"
}
mb_order() { grep -oE '^(push|gh (label create|pr create|pr edit|pr ready|pr comment))' "$mb_tmp/log" | tr '\n' '|'; }
mb_reviewers() { sed -n 's/.*reviewers\[\]=\([^ ]*\).*/\1/p' "$mb_tmp/log" | tr '\n' ' '; }
mb_tip() { git -C "$mb_tmp/origin.git" rev-parse "refs/heads/ci/merge-$1-into-staging"; }
mb_has() { git -C "$mb_tmp/origin.git" merge-base --is-ancestor "$2" "$(mb_tip "$1")"; echo "$?"; }
# A person pushing to the bot's branch: checks it out, changes a file, pushes.
mb_human() { # source file content -> the pushed commit
  local b="ci/merge-$1-into-staging"
  mb_git fetch -q origin
  mb_git checkout -q -B "$b" "origin/$b"
  mb_commit "$b" "resolve $2" "$2" "$3"
  mb_git rev-parse HEAD
}

ck "clean: the step succeeds"          "$(mb_run testnet '')" "0"
ck "clean: pushes, then opens"         "$(mb_order)" "push|gh pr create|"
ck "clean: not a draft"                "$(grep -c -- '--draft' "$mb_tmp/log")" "0"
ck "clean: the branch holds testnet"   "$(mb_has testnet "$(mb_git rev-parse testnet)")" "0"
# alice wrote #7 and reviewed it too, renovate[bot] is not a person, and carol's
# commit has no pull request.
ck "clean: authors and reviewers"      "$(mb_reviewers)" "alice bob carol "

ck "rerun: the step succeeds"          "$(mb_run testnet 42)" "0"
ck "rerun: does nothing"               "$(cat "$mb_tmp/log")" ""

# mainnet deletes c, which staging edited: a conflict that leaves no markers.
ck "conflict: the step succeeds"       "$(mb_run mainnet '')" "0"
ck "conflict: labels before the push"  "$(mb_order)" "gh label create|push|gh pr create|"
ck "conflict: opened as a draft"       "$(grep -c -- '--draft --label merge-conflict' "$mb_tmp/log")" "1"
ck "conflict: the commit names c" \
   "$(git -C "$mb_tmp/origin.git" log -1 --format=%B "$(mb_tip mainnet)" | grep -c '^    c$')" "1"
ck "conflict: author and reviewer"     "$(mb_reviewers)" "dave frank "

resolved=$(mb_human mainnet c -)
mb_commit mainnet "pr:11:erin" d 1
# hana merged a branch carrying pull request #99 and pushed the merge directly,
# so the merge commit has no pull request but #99's people are still asked.
mb_git checkout -q -b side mainnet
mb_commit side "pr:99:ivan" e 1
mb_git checkout -q mainnet
mb_git merge -q --no-ff -m "direct:hana" side
mb_git push -q origin mainnet
# A fork's pull request from a branch of the same name is listed first.
ck "update: the step succeeds"         "$(MB_FORK_PR=77 mb_run mainnet 43)" "0"
ck "update: pushes, then comments"     "$(mb_order)" "push|gh pr comment|"
ck "update: on ours, not the fork's"   "$(grep -c '^gh pr comment 43 ' "$mb_tmp/log")" "1"
# frank reviewed #11 and #99, so he comes first.
ck "update: inside a direct merge"     "$(mb_reviewers)" "frank erin hana ivan "
ck "update: keeps the resolution"      "$(mb_has mainnet "$resolved")" "0"
ck "update: carries the new commit"    "$(mb_has mainnet "$(mb_git rev-parse mainnet)")" "0"

# Someone edited a on the open pull request's branch; testnet now edits a too.
mine=$(mb_human testnet a human)
mb_commit testnet "pr:12:gina" a 3
ck "new conflict: the step succeeds"   "$(mb_run testnet 42)" "0"
ck "new conflict: gated, then pushed" \
   "$(mb_order)" "gh label create|gh pr edit|gh pr ready|push|gh pr comment|"
ck "new conflict: back to draft"       "$(grep -c 'pr ready 42 --undo' "$mb_tmp/log")" "1"
ck "new conflict: keeps their commit"  "$(mb_has testnet "$mine")" "0"

# The pull request was closed, so the branch is rebuilt from staging, and the
# API refuses every lookup.
ck "lookups fail: the step succeeds" \
   "$(MB_LOOKUP_FAIL=1 mb_run testnet '')" "0"
ck "lookups fail: no review requested" "$(mb_reviewers)" ""
# Three new commits, none with a pull request found, so two lookups each.
ck "lookups fail: warned"              "$(grep -c '::warning::lookup failed' "$mb_tmp/out")" "6"
ck "closed: the old branch is replaced" "$(mb_has testnet "$mine")" "1"

# The pull request is closed again, and someone pushes to its branch after the
# run fetched it: the run fails rather than overwrite them.
cat > "$mb_tmp/race.sh" <<RACE
git -C "$mb_tmp/seed" fetch -q origin
git -C "$mb_tmp/seed" checkout -q -B late origin/ci/merge-testnet-into-staging
echo late > "$mb_tmp/seed/late"
git -C "$mb_tmp/seed" add late
git -C "$mb_tmp/seed" commit -q -m late
git -C "$mb_tmp/seed" push -q origin late:ci/merge-testnet-into-staging
RACE
mb_commit testnet "pr:15:kim" f 1
ck "race: the push is refused" \
   "$(MB_ON_PR_LIST="$mb_tmp/race.sh" mb_run testnet '')" "1"
ck "race: their commit is kept"        "$(mb_has testnet "$(mb_git rev-parse late)")" "0"

# #14 has twenty reviewers: fifteen are asked, the most involved first.
mb_commit mainnet "pr:14:jo" g 1
ck "many: the step succeeds"           "$(mb_run mainnet 43)" "0"
ck "many: at most fifteen"             "$(grep -c requested_reviewers "$mb_tmp/log")" "15"
ck "many: says so"                     "$(grep -c '::warning::requesting review from 15 of 21' "$mb_tmp/out")" "1"

echo "== merge-branches: the post-merge script =="
# The script records its arguments, counts what it can see of the token, then
# runs MB_HOOK. pinned and locked stand in for Cargo.toml and Cargo.lock.
mb_git checkout -q staging
mkdir -p "$mb_tmp/seed/.github"
cat > "$mb_tmp/seed/.github/post-merge" <<'HOOK'
#!/bin/bash
printf '%s\n' "$@" > "$MB_HOOK_ARGS"
{ env; git config --list
  printf 'protocol=https\nhost=github.com\n\n' | GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/false git credential fill 2>/dev/null
} | grep -c tok-SECRET > "$MB_HOOK_SEEN"
eval "${MB_HOOK:-}"
HOOK
chmod +x "$mb_tmp/seed/.github/post-merge"
mb_git add .github/post-merge; mb_git commit -q -m "post-merge script"
mb_base=$(mb_git rev-parse HEAD)
echo staging > "$mb_tmp/seed/pinned"; echo staging > "$mb_tmp/seed/locked"
mb_git add pinned locked; mb_git commit -q -m "staging pins"; mb_git push -q origin staging
mb_source() { # name -> a new source from before staging set pinned and locked
  mb_git checkout -q -b "$1" "$mb_base"; mb_git push -q origin "$1"
}
mb_hook() { # source  open-pr  hook-commands -> the job's exit code
  rm -f "$mb_tmp/hook-args" "$mb_tmp/hook-seen"
  MB_POST_MERGE=.github/post-merge MB_HOOK="$3" MB_HOOK_ARGS="$mb_tmp/hook-args" MB_HOOK_SEEN="$mb_tmp/hook-seen" \
    mb_run "$1" "$2"
}
mb_msg() { printf '%s\n' "$(git -C "$mb_tmp/origin.git" log -1 --format=%B "$(mb_tip "$1")")"; }
mb_body() { sed -n '/^gh pr \(create\|comment\)/,/^gh /p' "$mb_tmp/log"; }
mb_file() { git -C "$mb_tmp/origin.git" show "$(mb_tip "$1"):$2"; }

mb_source all; mb_commit all "pr:20:lee" pinned all; mb_commit all "pr:20:lee" locked all
ck "no input: the script does not run" "$(rm -f "$mb_tmp/hook-args"; MB_HOOK_ARGS="$mb_tmp/hook-args" MB_HOOK_SEEN=/dev/null mb_run all ''; if [ -e "$mb_tmp/hook-args" ]; then echo 0; else echo 1; fi)" "0
1"
ck "no input: a draft, as before"      "$(grep -c -- '--draft --label merge-conflict' "$mb_tmp/log")" "1"
git -C "$mb_tmp/origin.git" update-ref -d refs/heads/ci/merge-all-into-staging

ck "resolves all: the job succeeds" \
   "$(mb_hook all '' 'git checkout -q --ours pinned locked && git add pinned locked')" "0"
ck "resolves all: given the conflicts" "$(tr '\n' ' ' < "$mb_tmp/hook-args")" "locked pinned "
ck "resolves all: sees no token"       "$(cat "$mb_tmp/hook-seen")" "0"
ck "checkout keeps no credentials" "$(python3 -c "
import yaml
d = yaml.safe_load(open('$mb_wf'))
print(next(x for x in d['jobs']['merge']['steps'] if 'checkout' in x.get('uses', ''))['with'].get('persist-credentials'))")" "False"
# What git would send to GitHub, from the helper the merge step installed.
mb_cred() {
  printf 'protocol=https\nhost=github.com\n\n' |
    GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/false git -C "$mb_tmp/work" credential fill 2>/dev/null | grep -c '^password=tok-SECRET$'
}
ck "resolves all: git has the token where GH_TOKEN is set" "$(GH_TOKEN=tok-SECRET mb_cred)" "1"
ck "resolves all: and not where it is not" "$(unset GH_TOKEN; mb_cred)" "0"
ck "resolves all: pushes, then opens"  "$(mb_order)" "push|gh pr create|"
ck "resolves all: not a draft"         "$(grep -c -- '--draft' "$mb_tmp/log")" "0"
ck "resolves all: keeps staging's pin" "$(mb_file all pinned)" "staging"
ck "resolves all: the commit names them" "$(mb_msg all | sed -n '/^Changed by `.github\/post-merge`:$/,$p' | tr '\n' '|')" \
   "Changed by \`.github/post-merge\`:|    locked|    pinned|"
ck "resolves all: the body names them" "$(mb_body | grep -c -e '^- `locked`$' -e '^- `pinned`$' -e 'Changed by `.github/post-merge`:')" "3"

ck "rerun: the script does not run"   "$(mb_hook all 42 'exit 1'; if [ -e "$mb_tmp/hook-args" ]; then echo 0; else echo 1; fi)" "0
1"

mb_source some; mb_commit some "pr:21:max" pinned some; mb_commit some "pr:21:max" locked some
ck "resolves some: the job succeeds" \
   "$(mb_hook some '' 'git checkout -q --ours pinned && git add pinned')" "0"
ck "resolves some: still a draft"      "$(grep -c -- '--draft --label merge-conflict' "$mb_tmp/log")" "1"
ck "resolves some: warns of the rest"  "$(mb_body | grep -c -e '^> - `locked`$' -e '^> - `pinned`$')" "1"
ck "resolves some: the commit" "$(mb_msg some | sed -n '/^Changed by/,$p' | tr '\n' '|')" \
   "Changed by \`.github/post-merge\`:|    pinned||Committed with these paths unresolved:|    locked|"

# The source moves pinned where staging did not touch it: a clean merge that
# the script undoes.
mb_git checkout -q -b clean staging; mb_git push -q origin clean
mb_commit clean "pr:22:noa" pinned moved; mb_commit clean "pr:22:noa" other 1
ck "edits a clean merge: the job succeeds" \
   "$(mb_hook clean '' 'git checkout -q HEAD -- pinned')" "0"
ck "edits a clean merge: given nothing" "$(cat "$mb_tmp/hook-args")" ""
ck "edits a clean merge: restored"     "$(mb_file clean pinned)" "staging"
ck "edits a clean merge: reported"     "$(mb_msg clean | sed -n '/^Changed by/,$p' | tr '\n' '|')" \
   "Changed by \`.github/post-merge\`:|    pinned|"
ck "edits a clean merge: not a draft"  "$(grep -c -- '--draft' "$mb_tmp/log")" "0"

ck "untouched: nothing reported" \
   "$(mb_commit clean "pr:23:ola" other 2; mb_hook clean 44 ':' >/dev/null; mb_body | grep -c 'Changed by')" "0"

mb_source fails; mb_commit fails "pr:24:pat" pinned fails
ck "fails: the job fails"              "$(mb_hook fails '' 'exit 3')" "1"
ck "fails: says so"                    "$(grep -c '::error::post-merge: .github/post-merge failed' "$mb_tmp/out")" "1"
ck "fails: nothing pushed or opened"   "$(cat "$mb_tmp/log")" ""
ck "commits: the job fails"            "$(mb_hook fails '' 'git add -A && git commit -q -m x')" "1"
ck "commits: says so"                  "$(grep -c 'committed, aborted or replaced the merge' "$mb_tmp/out")" "1"
ck "commits: nothing pushed or opened" "$(cat "$mb_tmp/log")" ""

ck "missing: the job fails" \
   "$(MB_POST_MERGE=.github/nope mb_run fails '')" "1"
ck "missing: says so" \
   "$(grep -c '::error::post-merge: .github/nope is not an executable file on staging' "$mb_tmp/out")" "1"
ck "missing: nothing pushed or opened" "$(cat "$mb_tmp/log")" ""
mb_git checkout -q staging; cp "$mb_tmp/seed/.github/post-merge" "$mb_tmp/seed/.github/plain"; chmod -x "$mb_tmp/seed/.github/plain"
mb_git add .github/plain; mb_git commit -q -m plain; mb_git push -q origin staging
ck "not executable: the job fails"     "$(MB_POST_MERGE=.github/plain mb_run fails '')" "1"

# Staged with its markers: no longer unmerged, but not resolved.
mb_source added; mb_commit added "pr:26:rio" pinned added
ck "stages markers: the job succeeds"   "$(mb_hook added '' 'git add pinned')" "0"
ck "stages markers: a draft"            "$(grep -c -- '--draft --label merge-conflict' "$mb_tmp/log")" "1"
ck "stages markers: the commit" "$(mb_msg added | sed -n '/^Changed by/,$p;/^Committed with/,$p' | tr '\n' '|')" \
   "Committed with these paths unresolved:|    pinned|"

mb_source githooks; mb_commit githooks "pr:29:uma" pinned githooks
ck "installs git hooks: the job succeeds" "$(mb_hook githooks '' 'for h in pre-push post-commit; do
    printf "#!/bin/sh\necho %s >> %s\n" "$h" "$MB_HOOK_ARGS.githooks" > ".git/hooks/$h"; chmod +x ".git/hooks/$h"
  done; git checkout -q --ours pinned && git add pinned')" "0"
ck "installs git hooks: none run"       "$(cat "$mb_tmp/hook-args.githooks" 2>/dev/null)" ""

mb_source moves; mb_commit moves "pr:30:val" pinned moves
ck "moves HEAD: the job fails"          "$(mb_hook moves '' 'git update-ref HEAD HEAD^')" "1"
ck "moves HEAD: says so"                "$(grep -c 'committed, aborted or replaced the merge' "$mb_tmp/out")" "1"
ck "moves HEAD: nothing pushed or opened" "$(cat "$mb_tmp/log")" ""

# Someone replaced the script on the open pull request's branch; staging's runs.
mb_hook all 42 'exit 0' >/dev/null
mb_human all .github/post-merge 'exit 7' >/dev/null
mb_commit all "pr:25:quinn" a all
ck "from the target: the job succeeds" "$(mb_hook all 42 ':')" "0"
ck "from the target: staging's ran"    "$(cat "$mb_tmp/hook-seen")" "0"

# The source edits a file staging deletes: a conflict without markers, kept
# by staging it. The name is not ASCII, which git quotes by default.
mb_git checkout -q staging; echo base > "$mb_tmp/seed/gône"; mb_git add gône; mb_git commit -q -m gône; mb_git push -q origin staging
mb_git checkout -q -b gone staging; mb_git push -q origin gone
mb_commit gone "pr:27:sam" gône kept
mb_commit staging "drop gône" gône -
ck "modify/delete: the job succeeds"    "$(mb_hook gone '' 'git add gône')" "0"
ck "modify/delete: given the name"      "$(cat "$mb_tmp/hook-args")" "gône"
ck "modify/delete: not a draft"         "$(grep -c -- '--draft' "$mb_tmp/log")" "0"
ck "modify/delete: named"               "$(mb_msg gone | sed -n '/^Changed by/,$p' | tr '\n' '|')" \
   "Changed by \`.github/post-merge\`:|    gône|"
ck "modify/delete: kept"                "$(mb_file gone gône)" "kept"
unset GIT_CONFIG_NOSYSTEM GIT_CONFIG_GLOBAL
rm -rf "$mb_tmp"

echo "== bump-advisories: updating the crates =="
ba_tmp="$(mktemp -d)"; mkdir -p "$ba_tmp/bin"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$ba_tmp/gitconfig"
git config -f "$GIT_CONFIG_GLOBAL" user.name test
git config -f "$GIT_CONFIG_GLOBAL" user.email test@example.com
git config -f "$GIT_CONFIG_GLOBAL" init.defaultBranch staging
# Each step's own run block, with the env its YAML and the workflow's give it.
cat > "$ba_tmp/step.py" <<'PYEOF'
import os, re, sys, yaml
wf, name, script = sys.argv[1:]
d = yaml.safe_load(open(wf))
st = next(x for x in d['jobs']['bump']['steps'] if x.get('name') == name)
vals = {'github.repository': 'o/r', 'inputs.target': 'staging', 'steps.app.outputs.token': 'tok-SECRET',
        'steps.app.outputs.app-slug': 'merge-bot', 'steps.bump.outputs.changed': os.environ.get('BA_CHANGED', '')}
def ref(m):
    r = m[1].strip()
    if r not in vals: sys.exit('unknown expression: ' + r)
    return vals[r]
for k, v in {**d['env'], **(st.get('env') or {})}.items():
    print(k + '=' + re.sub(r'\$\{\{(.*?)\}\}', ref, str(v)))
open(script, 'w').write(st['run'])
PYEOF
ba_step() { # step name, env assignments -> its exit code
  local name=$1 e; shift
  mapfile -t e < <(python3 "$ba_tmp/step.py" "$REPO/.github/workflows/bump-advisories.yml" "$name" "$ba_tmp/step.sh")
  (( ${#e[@]} )) || return 98
  ( cd "$ba_tmp/work" || exit 99
    env "${e[@]}" "$@" PATH="$ba_tmp/bin:$PATH" BA_LOG="$ba_tmp/log" BA_TMP="$ba_tmp" \
      GITHUB_SERVER_URL=https://github.com GITHUB_RUN_ID=1 GITHUB_WORKFLOW=w \
      RUNNER_TEMP="$ba_tmp/runner" GITHUB_OUTPUT="$ba_tmp/outputs" bash "$ba_tmp/step.sh" ) >> "$ba_tmp/out" 2>&1
}
# Three advisories on zip 8.6.0, which self_update pins, shaped as cargo-deny
# 0.20.2 reports them, after a log line and a warning that are not findings.
# `cargo update -p "$BA_FIX"` clears them; every `cargo update -p` changes
# Cargo.lock.
cat > "$ba_tmp/bin/cargo" <<'CARGOEOF'
#!/bin/bash
case "$*" in
  "pkgid "*) ;;
  "update -p "*) echo "$3" | tee -a "$BA_LOG" >> Cargo.lock;;
  "deny --format json check advisories"|"deny --offline --format json check advisories")
    [ -n "${BA_BROKEN:-}" ] && { echo "error: failed to fetch the advisory database" >&2; exit 1; }
    echo '{"type":"log","fields":{"level":"INFO","message":"fetching"}}' >&2
    echo '{"type":"diagnostic","fields":{"severity":"warning","code":"advisory-not-detected","message":"not encountered"}}' >&2
    [ -n "${BA_CLEAN:-}" ] && exit 0
    # Never fixed: on foo 1.0.0, which bar pins.
    [ -n "${BA_MIXED:-}" ] && jq -cn '{type: "diagnostic", fields: {severity: "error", code: "unmaintained",
      message: "foo", advisory: {id: "RUSTSEC-2026-0001", package: "foo", title: "foo"},
      graphs: [{Krate: {name: "foo", version: "1.0.0"}, parents: [{Krate: {name: "bar", version: "2.0.0"}}]}]}}' >&2
    grep -qxF "${BA_FIX:-}" Cargo.lock && exit "$([ -n "${BA_MIXED:-}" ] && echo 1 || echo 0)"
    for n in 7 8 9; do
      jq -cn --arg id "RUSTSEC-2026-036$n" '{type: "diagnostic", fields: {severity: "error", code: "vulnerability",
        message: " title \($id) ", advisory: {id: $id, package: "zip", title: " title \($id) "},
        graphs: [{Krate: {name: "zip", version: "8.6.0"}, parents: [{Krate: {name: "self_update", version: "1.3.0"}}]}]}}' >&2
    done
    exit 1;;
  *) echo "unexpected: cargo $*" >&2; exit 1;;
esac
CARGOEOF
chmod +x "$ba_tmp/bin/cargo"
git init -q --bare "$ba_tmp/origin.git"
printf '#!/bin/sh\necho push >> %q\n' "$ba_tmp/log" > "$ba_tmp/origin.git/hooks/pre-receive"
chmod +x "$ba_tmp/origin.git/hooks/pre-receive"
git init -q "$ba_tmp/seed"
echo lock > "$ba_tmp/seed/Cargo.lock"
git -C "$ba_tmp/seed" add Cargo.lock; git -C "$ba_tmp/seed" commit -q -m base
git -C "$ba_tmp/seed" push -q "$ba_tmp/origin.git" staging
ba_bump() { # env assignments -> the step's exit code
  rm -rf "$ba_tmp/work" "$ba_tmp/runner"; mkdir "$ba_tmp/runner"
  git clone -q --branch staging "$ba_tmp/origin.git" "$ba_tmp/work"
  : > "$ba_tmp/log"; : > "$ba_tmp/outputs"; : > "$ba_tmp/out"
  ba_step "Update the crates with advisories" "$@"
  echo "$?"
}
ba_ids() { cut -f1 "$ba_tmp/runner/bump-advisories/$1" | tr '\n' ' '; }
ba_all="RUSTSEC-2026-0367 RUSTSEC-2026-0368 RUSTSEC-2026-0369 "
ck "clean: the step succeeds"        "$(ba_bump BA_CLEAN=1)" "0"
ck "clean: nothing updated"          "$(cat "$ba_tmp/log")" ""
ck "parent fix: the step succeeds"   "$(ba_bump BA_FIX=self_update@1.3.0)" "0"
ck "parent fix: crate, then parent"  "$(tr '\n' ' ' < "$ba_tmp/log")" "zip@8.6.0 self_update@1.3.0 "
ck "parent fix: all fixed"           "$(ba_ids fixed)" "$ba_all"
ck "parent fix: none left"           "$(ba_ids after)" ""
ck "parent fix: Cargo.lock changed"  "$(cat "$ba_tmp/outputs")" "changed=true"
ck "crate fix: the step succeeds"    "$(ba_bump BA_FIX=zip@8.6.0)" "0"
ck "crate fix: parents untouched"    "$(tr '\n' ' ' < "$ba_tmp/log")" "zip@8.6.0 "
ck "unfixable: the step succeeds"    "$(ba_bump BA_FIX=nothing)" "0"
ck "unfixable: none fixed"           "$(ba_ids fixed)" ""
ck "unfixable: all left"             "$(ba_ids after)" "$ba_all"
ck "unfixable: Cargo.lock unchanged" "$(cat "$ba_tmp/outputs")" ""
ck "mixed: the step succeeds"        "$(ba_bump BA_FIX=zip@8.6.0 BA_MIXED=1)" "0"
ck "mixed: zip fixed"                "$(ba_ids fixed)" "$ba_all"
ck "mixed: foo left"                 "$(ba_ids after)" "RUSTSEC-2026-0001 "
ck "mixed: only the fix is kept"    "$(tr '\n' ' ' < "$ba_tmp/log"; tr '\n' ' ' < "$ba_tmp/work/Cargo.lock")" \
   "foo@1.0.0 zip@8.6.0 bar@2.0.0 lock zip@8.6.0 "
ck "broken cargo deny fails"         "$(ba_bump BA_BROKEN=1)" "1"
ck "broken: nothing updated"         "$(cat "$ba_tmp/log")" ""

echo "== bump-advisories: the pull request and the issue =="
# BA_PR and BA_ISSUE are the open pull request and issue, BA_SHA the blob the
# pull request's branch holds as Cargo.lock, BA_OLD the issue's body. Writes
# are logged, and each --body is kept as body.<command>.
cat > "$ba_tmp/bin/gh" <<'GHEOF'
#!/bin/bash
[ "${GH_TOKEN:-}" = tok-SECRET ] || { echo "gh without the app token: gh $*" >&2; exit 1; }
jq_arg() { local prev=; for a in "$@"; do [ "$prev" = --jq ] && { echo "$a"; return; }; prev=$a; done; }
case "$*" in
  "pr list --head ci/bump-advisories-into-staging --base staging "*)
    jq -n --arg n "${BA_PR:-}" '[{number: 99, isCrossRepository: true}] + [$n | select(. != "") | {number: tonumber, isCrossRepository: false}]' \
      | jq -r "$(jq_arg "$@")";;
  "api repos/o/r/contents/Cargo.lock?ref=ci/bump-advisories-into-staging "*) echo "${BA_SHA:-}";;
  "api users/"*) echo 12345;;
  "issue list --label cargo-advisories "*)
    jq -n --arg n "${BA_ISSUE:-}" '[{number: 98, title: "cargo deny advisories on mainnet"}]
      + [$n | select(. != "") | {number: tonumber, title: "cargo deny advisories on staging"}]' \
      | jq -r "$(jq_arg "$@")";;
  "issue view"*) cat "$BA_OLD";;
  "pr create"*|"pr edit"*|"pr close"*|"label create"*|"issue create"*|"issue edit"*|"issue comment"*|"issue close"*)
    echo "gh $1 $2" >> "$BA_LOG"
    prev=; for a in "$@"; do [ "$prev" = --body ] && printf '%s\n' "$a" > "$BA_TMP/body.$1-$2"; prev=$a; done;;
  *) echo "unexpected: gh $*" >&2; exit 1;;
esac
GHEOF
chmod +x "$ba_tmp/bin/gh"
ba_publish() { # env assignments -> the step's exit code
  : > "$ba_tmp/log"; rm -f "$ba_tmp"/body.*
  BA_CHANGED="$(sed -n 's/^changed=//p' "$ba_tmp/outputs")" \
    ba_step "Open, update or close the pull request and the issue" "$@"
  echo "$?"
}
ba_log() { tr '\n' '|' < "$ba_tmp/log"; }
ba_branch() { git -C "$ba_tmp/origin.git" show "ci/bump-advisories-into-staging:$1"; }
ba_bump BA_FIX=self_update@1.3.0 >/dev/null
ck "fixed: the step succeeds"        "$(ba_publish)" "0"
ck "fixed: pushes, then opens"       "$(ba_log)" "push|gh pr create|"
ck "fixed: the branch holds the fix" "$(ba_branch Cargo.lock | tail -1)" "self_update@1.3.0"
ck "fixed: the body names them"      "$(grep -c '^- \[RUSTSEC-2026-036[789]\](https://rustsec.org/advisories/RUSTSEC-2026-036[789].html) in `zip 8.6.0`: title RUSTSEC' "$ba_tmp/body.pr-create")" "3"
ck "fixed: so does the commit"       "$(git -C "$ba_tmp/origin.git" log -1 --format=%B ci/bump-advisories-into-staging | grep -c '^- \[RUSTSEC')" "3"
# Each run starts from a fresh checkout, as on a runner.
ba_fixed() { ba_bump BA_FIX=self_update@1.3.0 >/dev/null; git -C "$ba_tmp/work" hash-object Cargo.lock; }
ck "same lock: does nothing"         "$(ba_publish BA_PR=5 BA_SHA="$(ba_fixed)")$(ba_log)" "0"
ba_fixed >/dev/null
git -C "$ba_tmp/origin.git" update-ref -d refs/heads/ci/bump-advisories-into-staging
ck "new lock: pushes, then edits"    "$(ba_publish BA_PR=5 BA_SHA=0123)$(ba_log)" "0push|gh pr edit|"
ba_fixed >/dev/null
git -C "$ba_tmp/origin.git" update-ref -d refs/heads/ci/bump-advisories-into-staging
ck "a fork's pull request is not ours" "$(ba_publish)$(ba_log)" "0push|gh pr create|"

ba_bump BA_FIX=nothing >/dev/null
ck "unfixable: closes, then opens an issue" "$(ba_publish BA_PR=5)$(ba_log)" "0gh pr close|gh label create|gh issue create|"
ck "unfixable: the issue names them" "$(grep -c '^- \[RUSTSEC' "$ba_tmp/body.issue-create")" "3"
cp "$ba_tmp/body.issue-create" "$ba_tmp/issue"
cp "$ba_tmp/issue" "$ba_tmp/old"
ck "same issue: no edit"             "$(ba_publish BA_ISSUE=3 BA_OLD="$ba_tmp/old")$(ba_log)" "0gh label create|"
grep -v 0369 "$ba_tmp/issue" > "$ba_tmp/old"
ck "a new one: edits, and comments"  "$(ba_publish BA_ISSUE=3 BA_OLD="$ba_tmp/old")$(ba_log)" "0gh label create|gh issue edit|gh issue comment|"
ck "the comment names only it"       "$(grep -c '^- \[RUSTSEC-2026-0369\]' "$ba_tmp/body.issue-comment"); $(grep -c '^- ' "$ba_tmp/body.issue-comment")" "1; 1"
sed 's/zip 8.6.0/zip 8.5.0/' "$ba_tmp/issue" > "$ba_tmp/old"
ck "a new version: edits, no comment" "$(ba_publish BA_ISSUE=3 BA_OLD="$ba_tmp/old")$(ba_log)" "0gh label create|gh issue edit|"

ba_bump BA_CLEAN=1 >/dev/null
ck "clean: closes both"              "$(ba_publish BA_PR=5 BA_ISSUE=3)$(ba_log)" "0gh pr close|gh issue close|"
ck "clean: neither, nothing"         "$(ba_publish)$(ba_log)" "0"
# ci.yml's credential-helper job checks merge-branches.yml's copy.
ck "the same credential helper"      "$(grep -h -E "^ *helper='" "$REPO"/.github/workflows/{merge-branches,bump-advisories}.yml | sed 's/^ *//' | sort -u | wc -l)" "1"

unset GIT_CONFIG_NOSYSTEM GIT_CONFIG_GLOBAL
rm -rf "$ba_tmp"

rm -rf "$no_aws"
echo
echo "  ${pass} passed, ${fail} failed"
exit $(( fail > 0 ))
