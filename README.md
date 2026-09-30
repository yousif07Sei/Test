# CI/CD demo

A small Laravel 12 app used to demonstrate a complete CI/CD setup: tests on
every push, build once, atomic deploys to staging and production over
self-hosted runners, an approval gate, rollback, and servers configured as
code.

**Read [`docs/devops.md`](docs/devops.md)**. That is what this repository is
about.

## What is where

```
.github/workflows/
  ci.yml                  lint, format, PHP 8.2 + 8.3 tests, JS tests, build,
                          script checks, end-to-end deploy test, publish build
  deploy-staging.yml      development -> staging, automatic once CI is green
  deploy-production.yml   main -> production, CI-verified, behind approval
  rollback.yml            previous release, one switch
  provision.yml           server config: plan, then apply

scripts/
  app-deploy              atomic deploy / rollback / status (runs on the box)
  build-release.sh        builds a commit once, publishes refs/builds/<sha>
  smoke-test.sh           black-box checks against a live URL
  provision.sh            renders + validates + applies server config
  provision/              per-environment values and the templates
  install-runner.sh       registers a self-hosted GitHub Actions runner

tests/deploy/atomic-deploy.sh   runs the real deploy script end to end in CI
```

## Run it locally

```bash
composer install && npm install
cp .env.example .env && php artisan key:generate
touch database/database.sqlite && php artisan migrate
php artisan test && npm test          # the test suites
tests/deploy/atomic-deploy.sh         # the deploy model, end to end
```
