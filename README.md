# gh-actions

The reusable workflows and composite actions that aleo-labs-protocol
repositories share: starting and running on the self-hosted runner fleet, and
merging branches forward (`merge-branches.yml`). The fleet itself — the boxes,
their provisioning and the AWS role `start-runner.yml` assumes — is managed
elsewhere.

This repository is public so that public repositories can call it: GitHub does
not let a public repository use actions from a private one. Nothing here is
secret. What decides who can start a box is the AWS role's trust policy, which
admits named caller repositories only.

## Using it
Several repositories start runners from CI. The logic is published once, as a
reusable workflow plus composite actions, so a fix lands once.

```yaml
jobs:
  # ONE start job. It sizes the whole fleet and starts what is missing, so there
  # is no second caller to keep in step with this one. actions:read is what lets
  # it count the queue; secrets: inherit carries the runner-census key.
  start-runners:
    uses: aleo-labs-protocol/gh-actions/.github/workflows/start-runner.yml@v2
    permissions: { id-token: write, contents: read, actions: read }
    secrets: inherit
    with:
      role-to-assume: ${{ vars.RUNNER_ROLE_ARN }}
      runner-app-id: ${{ vars.RUNNER_APP_ID }}
    # Rejects pull_request_target outright, then admits non-PR triggers and
    # same-repo PRs. Note the first clause: `event_name != 'pull_request'` is
    # TRUE for a pull_request_target event, so an `||` guard short-circuits and
    # lets it through -- on the one trigger where the token is writable.
    if: >-
      github.event_name != 'pull_request_target' &&
      (github.event.pull_request == null ||
       github.event.pull_request.head.repo.full_name == github.repository)

  gpu-test:
    needs: start-runners
    runs-on: [self-hosted, linux, x64, gpu, sm_89]
    steps:
      - uses: aleo-labs-protocol/gh-actions/.github/actions/gpu-runner-preflight@v2
      - uses: actions/checkout@v5
        with: { persist-credentials: false }
      - run: cargo test --release --features cuda      # your own command
      - uses: aleo-labs-protocol/gh-actions/.github/actions/gpu-runner-report@v2
        if: always()
```

The split is by shape, not by taste. `start-runner` is an entire job, so it is a
reusable workflow — the caller cannot set `runs-on` for a composite action.
Preflight and report are steps inside a job the caller must own, because the
test command differs per repository, so they are composite actions — a reusable
workflow cannot be interleaved with a caller's own steps.

## Giving a caller the fleet-wide view

Optional. Without it a caller sizes the fleet from its own queue alone, which is
smaller than the truth whenever another repository is also building.

The org-wide count needs to ask GitHub which runners are busy, from inside a
job on `ubuntu-latest` — so it needs a credential that reaches a workflow, and
a private key only reaches one through a secret.

**Use a single-purpose GitHub App.** A key in org secrets can mint every
permission its app holds, for any workflow in the org that can read secrets. The
app that administers this fleet must therefore not be the one whose key goes
there: it can write org secrets, and that would be handing that power to CI.

One app, one permission:

| | |
| --- | --- |
| Organization → Self-hosted runners | **Read-only** |
| everything else | untouched — no repository permissions at all |
| Webhook | off |

Create it, **generate a private key**, then **install it** on the org — creating
and installing are separate steps, and an uninstalled app authenticates fine
while resolving no installation, which looks like a broken key and is not.

Then store the two halves:

```sh
gh variable set RUNNER_APP_ID  --org aleo-labs-protocol --visibility all --body <app id>
gh secret   set RUNNER_APP_KEY --org aleo-labs-protocol --visibility all < path/to/key.pem
```

The id is a **variable**, not a secret: it is not sensitive, and having it in
the log makes a misconfiguration diagnosable instead of mysterious.

A caller then passes both through:

```yaml
  start-cpu-runners:
    uses: aleo-labs-protocol/gh-actions/.github/workflows/start-runner.yml@v2
    permissions: { id-token: write, contents: read, actions: read }
    with:
      role-to-assume: ${{ vars.RUNNER_ROLE_ARN }}
      label: cpu
      runner-app-id: ${{ vars.RUNNER_APP_ID }}
    secrets:
      runner_app_key: ${{ secrets.RUNNER_APP_KEY }}
```

No thresholds in the caller: how deep a queue justifies another box is a
property of the fleet, and it lives with the fleet. So is which boxes there are:
the caller names only the label its jobs need, and the fleet is every box whose
`RunnerLabel` tag is that label, each stepping down its own `CapacityLadder` tag
when its AZ is short. Provisioning writes both.

**The secret name has underscores on purpose.** GitHub secret names cannot contain
hyphens, so a `runner-app-key` secret could never be supplied by `secrets: inherit`
— it would fall back to per-repo sizing silently, forever, with nothing in any
log to say so.

Everything here fails **open**: no variable, no secret, a key that does not
match, an app installed elsewhere, a rate-limited listing. Each falls back to
`busy = 0` — the fleet is then sized from this repository's queue alone, which
under-provisions rather than over-provisions, and a run is never reddened by a
count it could not take.

## Merging branches

`merge-branches.yml` keeps one pull request open from each source branch into a
target branch while the source has commits the target lacks.

- The pull request comes from `ci/merge-<source>-into-<target>`. Review is
  requested from the authors and reviewers of the merged pull requests behind
  the new commits.
- A conflict is committed with its markers. The pull request gets the
  `merge-conflict` label and is a draft until people push a resolution.
- When the source moves, the next run merges it into the open pull request's
  branch. It never force-pushes that branch, so a resolution is kept.
- The target must merge these pull requests with a merge commit. A squash or
  rebase leaves the source's commits off the target, so the next run opens
  the same pull request again.

The caller owns the schedule and the concurrency group, and grants the check
job its permissions:

```yaml
on:
  schedule:
    - cron: '17 * * * *'
  workflow_dispatch:

permissions: {}

concurrency: merge-into-staging

jobs:
  merge:
    uses: aleo-labs-protocol/gh-actions/.github/workflows/merge-branches.yml@v2
    permissions: { contents: read, pull-requests: read }
    with:
      target: staging
      sources: testnet mainnet
    secrets:
      MERGE_BOT_APP_KEY: ${{ secrets.MERGE_BOT_APP_KEY }}
```

**It pushes as a GitHub App**, because a push made with `github.token` starts no
workflows. The App is the single-purpose **aleo-labs merge-bot**, for the reason
given under [Giving a caller the fleet-wide view](#giving-a-caller-the-fleet-wide-view).
It holds contents, pull requests, issues and workflows write, and nothing else.
Install it on the calling repository.

Its key lives in an environment named **`merge-bot`** in the calling
repository, whose deployment branches admit only the target branch:

```sh
gh secret   set MERGE_BOT_APP_KEY   --env merge-bot -R <repo> < path/to/key.pem
gh variable set MERGE_BOT_CLIENT_ID --env merge-bot -R <repo> --body <client id>
```

The merge job sets that environment itself, because a calling job cannot. The
caller still passes the secret by name, as above. Its own job has no
environment, so the value it passes is empty, and the merge job receives the
environment's value instead.

The App can push changes to `.github/workflows`, so a leaked key could push a
branch whose workflow reads **repository** secrets. Keep sensitive secrets in
environments that admit only protected branches.

A bot push to a pull request keeps approvals given before it, unless the
target's rules dismiss stale approvals or require approval of the most recent
push.

### Resolving a repository's own conflicts

A caller can name a script that runs after every merge, before the commit:

```yaml
    with:
      target: staging
      sources: testnet mainnet
      post-merge: .github/merge-fixup.sh
```

- The merge runs as `git merge --no-ff --no-commit`, also when it is clean.
  The script then runs from the repository root with the merge in progress.
  It runs as a copy outside the checkout, so it cannot find files next to
  itself through `$0`.
- Its arguments are the unmerged paths, possibly none. `TARGET` and `SOURCE`
  hold the branch names.
- It may edit files and `git add` them. It must not commit or abort the merge.
  Everything it leaves in the working tree is committed, untracked files too.
- If it fails, or does not leave the same merge in progress, the job fails
  and nothing is pushed. A missing or non-executable script fails the job too.
- Paths still unmerged after it, or staged with conflict markers in them, are
  committed as they are, and the pull request is a draft, as above. If none
  are left, it is not.
- The commit message and the pull request name every path the script edited
  or resolved, so reviewers know where to look. This includes an edit to a
  cleanly merged file, such as a dependency pin the source moved.

The script is read from the target branch, never from the source or the pull
request's branch. Those take pushes without review, and the target is
protected. That protection is what makes the script trusted.

The script runs in a step with no token, and the checkout keeps no
credentials. Git asks a credential helper, which answers only in the steps
whose env has the token: the merge before the script and the push after it. This is not a sandbox: the script shares the runner and the
checkout with the push step. It keeps the token out of reach of a script that
misbehaves, not one written to attack. The commit and the push run no git
hooks, so a hook the script installs, say through a cargo build, never sees
the token. Without credentials, the script cannot
fetch objects the merge did not, so in a private repository it should read
only the working tree and the index stages (`git show :1:path`, `:2:`, `:3:`).

## Versioning

Callers pin a major tag, currently `@v2`. The AWS role trusts `start-runner.yml` **only at a `v*` tag**
— not a branch, not a SHA — so a caller pinned any other way is denied at STS
with "Not authorized to perform sts:AssumeRoleWithWebIdentity", which names
neither the ref nor the claim. Every caller should run `check-shared-refs`: it
fails on a ref that is not `@vN`.

That makes the org setting "Require actions to be pinned to a full-length commit
SHA" incompatible with this repository: turned on, it rejects every caller's
`@v2`, and a SHA pin is refused by the role. Change the role's trust policy
before turning it on.

A ruleset on all tags restricts creating, **updating** and deleting them to its
bypass list. Moving a major tag is an update, and it changes what runs with
the fleet's AWS credentials in every caller at once, so move it deliberately.
A change callers must adapt to gets a new major tag instead, as v2 did when it
dropped the `fleet` and `ladder` inputs.

**Trying a change before it is released** needs a tag too, since the role
trusts nothing else: someone on the bypass list tags the commit `v0-<topic>`,
a caller branch points at that tag, and the tag is deleted afterwards. The
ruleset covers it like any other `v*`, and `check-shared-refs` fails on it, so it
cannot be merged by accident.

The actions the shared workflows use run with their callers' credentials: the
fleet's AWS role, an App key. A caller pins this repository, not what it pulls
in, so they are pinned to commit SHAs; Dependabot proposes the updates.

## Development

```sh
./lint-workflow-shell.sh   # shellcheck the shell inside the workflow and action YAML
./test.sh                  # the steps' own shell, run against stubs; no AWS
```
