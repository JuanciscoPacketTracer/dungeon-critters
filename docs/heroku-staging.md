# Heroku staging

This deployment runs the API and the outbox worker as separate Heroku
processes. It expects the four SQL migrations to be applied to the target
PostgreSQL database before either process handles real traffic.

## Build and processes

The repository pins Ruby to the 3.4 release line in `Gemfile` and declares
Puma explicitly. Heroku uses the root `Procfile`:

```text
web: RACK_ENV=production bundle exec puma -b tcp://0.0.0.0:$PORT server/config.ru
worker: RACK_ENV=production bundle exec ruby server/bin/outbox_worker.rb
```

Both processes must run with `RACK_ENV=production`; the Procfile sets it
explicitly so neither depends on the application's development default. The
`web` process must use Heroku's `$PORT` and bind to `0.0.0.0`. Scale the worker
separately:

```powershell
heroku ps:scale web=1 worker=1 --app <HEROKU_APP_NAME>
heroku ps --app <HEROKU_APP_NAME>
heroku logs --tail --app <HEROKU_APP_NAME>
```

## Config Vars

Required by the API and/or worker:

- `DATABASE_URL`: PostgreSQL connection URI from the Supabase Connect dialog.
  For a persistent Heroku process, use the shared pooler in session mode,
  normally on port `5432`; do not commit the URI.
- `RESEND_API_KEY`: Resend API key placeholder, for example
  `<RESEND_API_KEY>`.
- `RESEND_FROM_EMAIL`: verified sender address, for example
  `Dungeon Critters <noreply@example.invalid>`.
- `PUBLIC_API_URL`: HTTPS public API origin, for example
  `https://<HEROKU_APP_NAME>.herokuapp.com`.
- `VERIFICATION_TOKEN_SECRETS`: token-key JSON configured for the server;
  provide a secret placeholder such as `<VERIFICATION_TOKEN_SECRETS_JSON>`.
- `VERIFICATION_TOKEN_KEY_VERSION`: active verification-token key version,
  for example `v1`.
- `SAVE_REFERENCE_CATALOG_JSON`: JSON catalog accepted by the save-upload
  validator. Keep it below Heroku's combined Config Vars limit of 64 KiB.

Optional worker tuning variables:

- `OUTBOX_POLL_INTERVAL`
- `OUTBOX_BACKOFF_BASE`
- `OUTBOX_BACKOFF_MAX`
- `OUTBOX_MAX_ATTEMPTS`

`RACK_ENV=production` is mandatory for both Heroku processes. It enables
production HTTPS and verification-secret checks; do not replace it with the
development default. Do not put secret values in Git, a Procfile, or chat.
For a local PowerShell run, set it only in the current process, for example:

```powershell
$env:DATABASE_URL = '<DATABASE_URL>'
$env:RESEND_API_KEY = '<RESEND_API_KEY>'
$env:VERIFICATION_TOKEN_SECRETS = '<VERIFICATION_TOKEN_SECRETS_JSON>'
```

For Heroku, enter values with `heroku config:set` from a private terminal or
the Heroku dashboard; never paste them into repository files.

## Migration order and transaction safety

The four migration files were reviewed for PostgreSQL transaction
compatibility. They contain `CREATE TABLE`, `CREATE INDEX`, `ALTER TABLE`, and
one idempotent `DO` block; they do not contain top-level transaction control
statements, `CREATE INDEX CONCURRENTLY`, `VACUUM`, or another operation that
must run outside a transaction. The `BEGIN` inside the `DO` block is PL/pgSQL
block syntax, not a transaction boundary. They can therefore be applied as
one transaction.

Run this single command from a trusted machine with the target
`DATABASE_URL`. `--single-transaction` wraps all four `-f` inputs in one
transaction, and `ON_ERROR_STOP=1` makes the first SQL error roll back the
whole batch instead of leaving later migrations unapplied:

```powershell
$env:DATABASE_URL = '<DATABASE_URL>'
psql $env:DATABASE_URL --single-transaction --set=ON_ERROR_STOP=1 `
  -f server/db/001_sessions.sql `
  -f server/db/002_outbox_retry_state.sql `
  -f server/db/20261119_34_cloud_save_versions.sql `
  -f server/db/20261120_25_public_profiles.sql
```

The order is required because later migrations depend on earlier session,
outbox, save-version, and public-profile structures. A successful command
commits all four together; a failed command must be treated as a blocked
deployment and investigated before retrying. Do not rerun the files
individually as a workaround.

Transaction evidence: using the Node `pg` client against disposable
PostgreSQL, all four migrations were executed inside one transaction, then a
separate SQL error was induced and `ROLLBACK` left zero tables. This verifies
rollback after an induced SQL error, not failure inside a migration, and does
not verify the `psql` binary. The documented `psql` procedure should still be
validated with the target client before staging deployment.

## Local checks before staging

Install dependencies and run the headless suite without real credentials:

```powershell
bundle install
bundle exec ruby test/run.rb
```

To check the API process locally with synthetic configuration, set
placeholders appropriate for the selected test path, start:

```powershell
$env:PORT = '9292'
$env:RACK_ENV = 'production'
bundle exec puma -b tcp://127.0.0.1:$env:PORT server/config.ru
```

Then use a separate terminal to request the existing verification page:

```powershell
Invoke-WebRequest http://127.0.0.1:9292/v1/accounts/verify-email
```

The application has no dedicated health endpoint. Do not start the real worker
against an unprepared database: it requires `DATABASE_URL`, the Resend and
verification settings, and the migrated outbox schema. Once those are
available in staging, start it through the Heroku `worker` process and verify
`heroku logs` contains `outbox worker started`.

Synthetic smoke validation recorded for this package: Puma and the worker
started against disposable PostgreSQL with synthetic configuration, and the
verification-page HTTP request returned `200`. This did not send real email
through Resend. The separate Node `pg` transaction check induced a SQL error
after the migrations and verified that `ROLLBACK` left zero tables; it did not
test a failure inside a migration.

The upload smoke test must use a synthetic account, token, and trainer payload
from the test fixtures or catalog. It must not use a real save or secret.
