# DevOps: how this repository ships

The app here is a placeholder: a stock Laravel 12 page and one tested JS
module. It exists so the pipeline has something real to lint, test, build and
deploy. The pipeline is the point.

## The flow in one picture

```
 feature branch ──PR──► development ──PR──► main ──(approval)──► production
                            │                 │
                        CI green          CI green
                            │                 │
                   refs/builds/<sha>   refs/builds/<sha>
                            │
                   auto-deploy staging
```

- Work lands on **`development`** through pull requests. Every push there runs
  CI and, once CI is green, **deploys to staging automatically**.
- **`main`** is production. A release is a PR from `development` into `main`.
  When it merges, CI runs again, and the production deploy waits for a
  **human approval** in the `production` environment.
- Both environments deploy **the same build**. CI builds each tested commit
  **once** and publishes it; the servers never run `composer` or `npm`.

## 1. CI (`.github/workflows/ci.yml`)

Runs on every push to `main`/`development` and on every pull request.

| Job | What it proves |
|---|---|
| **PHP tests (8.2, 8.3)** | every PHP file parses (`php -l`), Pint formatting holds, PHPUnit passes, on both versions |
| **JS tests** | Vitest passes and the Vite bundle builds |
| **Deploy & provision scripts** | the shell scripts parse, and both environments' server config renders with no unfilled `@PLACEHOLDER@` |
| **Atomic deploy (end to end)** | runs the real deploy script against a throwaway server layout, see below |
| **Build release** | pushes only, after all of the above: builds the release once and publishes it as `refs/builds/<sha>` |

### The end-to-end deploy test

`tests/deploy/atomic-deploy.sh` runs `scripts/app-deploy` for real on
GitHub's runner. It uses a stand-in "GitHub" remote, real `git archive`, a real
Laravel boot, real migrations on SQLite, and a real HTTP `/up` served from
`current`. It proves:

1. a deploy unpacks CI's build and never runs composer on the box
2. a second deploy switches to a new release
3. a commit that cannot boot never gets a build, and built on the box it fails
   **before** the switch, with the live site untouched
4. rollback switches to the previous release
5. a release that fails its health check **after** the switch is switched back
   automatically
6. old releases are pruned
7. `--build-here` still deploys a commit CI never built (the emergency path)

This is the part to show someone: it demonstrates the whole deploy model
without any server.

## 2. Build once (`scripts/build-release.sh`)

After the tests pass on a push, CI installs production dependencies, builds the
frontend, writes a `BUILD` file (source commit, time, versions, the Actions
run), and records **source + `vendor/` + `public/build/`** as a git commit.
That commit is pushed to `refs/builds/<sha>`.

Why a git ref and not an uploaded tarball: the runner that deploys is an
unprivileged user, and anything it handed to `sudo` could be swapped. A ref is
fetched **by root, from GitHub itself**, and its tree hash is identical on
every box. That is what "promote the same artifact" means here.

## 3. Atomic deploys (`scripts/app-deploy`)

Each server keeps this layout:

```
/var/www/app/
  repo.git/            the git source; fetched, never checked out
  releases/<id>/       one per deploy: <UTC timestamp>-<short sha>
  shared/.env          the box's only .env
  shared/storage/      logs, sessions, uploads, database backups
  current -> releases/<id>   the only thing that switches
```

A deploy:

1. fetches and resolves the ref to a SHA (the ref is validated first: it
   reaches git as root)
2. fetches CI's build of it, `refs/builds/<sha>`, and refuses if there is none
3. unpacks it into a new `releases/<id>/`, linking `.env` and `storage/`
   to `shared/`
4. **boot-checks** the release (`artisan about`, `route:list`)
5. **backs up the database** (online SQLite backup; keeps the last 20)
6. runs **migrations** from the new release while the old one still serves
7. **switches** `current` in one `rename(2)`, so a request sees the old
   release or the new one, never a half-written link
8. reloads Apache and restarts the queue worker
9. **health-checks** `/up`, and switches straight back if it fails
10. prunes to the last 5 releases

Nothing touches `current` until steps 1–6 succeed. A failure there leaves the
live site exactly as it was, and the half-built release is removed.

**One rule follows from it:** a migration must work with the release *before*
it, because the old code runs on the new schema until the switch, and a
rollback moves only the code. Expand, then contract: add a column in one
release, drop the old one in a later release.

```bash
sudo app-deploy staging github/development   # deploy
sudo app-deploy production <sha>             # deploy an exact commit
sudo app-deploy production rollback          # previous release
sudo app-deploy production status            # list releases, mark the live one
```

## 4. Deploy workflows

| Workflow | Trigger | Runs on |
|---|---|---|
| `deploy-staging.yml` | CI green on a **push** to `development`, or manual | `[self-hosted, app, staging]` |
| `deploy-production.yml` | CI green on a push to `main`, a `v*` tag, or manual | a `verify` job on GitHub, then `[self-hosted, app, production]` behind approval |
| `rollback.yml` | manual, pick the environment | the box; production needs approval |
| `provision.yml` | manual; plan by default, tick *apply* to change | the box; production apply needs approval |

Production's `verify` job resolves the ref to an exact SHA and **refuses** it
unless CI passed for that commit. There is an `allow_untested` escape hatch for
emergencies, and it is loud in the log on purpose. The reviewer is never asked
to approve a commit CI has not passed.

After each deploy the workflow runs `scripts/smoke-test.sh` against the live
URL: `/up`, the page renders, the built assets are served, the error page does
not leak debug output, and (production) the page reports the exact commit that
was approved.

**Why self-hosted runners:** the servers sit on a private network that
GitHub's runners cannot reach. The runner on each box dials **out** to GitHub,
so nothing inbound has to be opened.

## 5. Servers as code (`scripts/provision.sh`)

Everything on a box that is not the app is rendered from
`scripts/provision/templates/` with the values in
`scripts/provision/<env>.conf`:

- the Apache vhost
- `app-queue.service`, `app-scheduler.service` + `.timer` (systemd)
- the runner's **sudoers** rule, which gives it root for exactly two scripts
- `/usr/local/sbin/app-deploy` itself, installed outside the tree it deploys,
  so what root runs changes only when a box is provisioned

```bash
sudo scripts/provision.sh staging            # plan: print a diff, change nothing
sudo scripts/provision.sh staging --apply    # write, validate, reload
scripts/provision.sh staging --render /tmp/x # render only (what CI does)
```

With `--apply`, every group is **validated before anything reloads**:
`visudo -c`, `systemd-analyze verify`, `apache2ctl configtest`. A group that
fails is rolled back from its backups. It refuses to run on a machine whose
hostname does not match the config, so `production` typed on the staging box
cannot write the wrong config. Change a box by editing the templates, never the
box, because the next provision overwrites hand edits.

## 6. Setting up a box (when you have one)

On a fresh Debian/Ubuntu machine with Apache, PHP 8.2 and git:

1. Name it `app-staging` (or `app-production`), matching `EXPECTED_HOSTNAME`.
2. Create the layout and a bare clone that root can fetch over SSH, using a
   read-only **deploy key** on the repo:
   ```bash
   mkdir -p /var/www/app/{releases,shared/storage}
   git clone --bare --origin github git@github.com:<owner>/<repo>.git /var/www/app/repo.git
   git --git-dir=/var/www/app/repo.git config remote.github.fetch '+refs/heads/*:refs/remotes/github/*'
   ```
   Put the box's `.env` in `shared/.env`.
3. Register the runner (token: Settings → Actions → Runners → New):
   ```bash
   sudo scripts/install-runner.sh staging <token>
   ```
4. Do the first deploy by hand, then provision (sudoers, units, vhost):
   ```bash
   sudo scripts/app-deploy staging github/development
   sudo /var/www/app/current/scripts/provision.sh staging --apply
   ```
5. In the repo settings:
   - **Variables:** `DEPLOY_ENABLED=true`, `STAGING_URL`, `PRODUCTION_URL`
   - **Environments:** `production` with required reviewers (the approval
     gate), and `staging`
   - **Branch protection** on `main` and `development`: require the CI checks

Until `DEPLOY_ENABLED` is set, the deploy, rollback and provision jobs are
skipped, so CI runs green on its own and nothing waits for a runner that does
not exist.

## Three routes, and which change takes which

| Change to | Reaches a box |
|---|---|
| app code, `scripts/smoke-test.sh` | with the deploy of the release that carries it |
| `.github/workflows/deploy-*.yml` | once it is on **`main`**: `workflow_run` workflows always run from the default branch |
| `scripts/app-deploy`, `scripts/provision.sh` and its templates | only when **Provision** runs, and it runs the copy in `current`, so **deploy first, then provision** |

## Recovering

- **A deploy failed.** If it failed before the switch, nothing changed. If the
  health check failed after it, the script already switched back.
- **Bad code is live.** Run the *Rollback* workflow, or
  `sudo app-deploy production rollback`.
- **A migration went wrong.** Rollback moves code only. Restore the backup the
  deploy took, from `shared/storage/backups/`, then roll back.
