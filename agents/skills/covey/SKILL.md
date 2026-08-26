---
name: covey
description: >
  Manage the covey local PHP development environment on this machine.
  Use for: serving a project at a .localhost URL, starting/stopping the local
  web server or PHP-FPM, listing local sites, diagnosing why a .localhost site
  is not loading, PHP version selection for a site, and local MySQL/Redis/Mailpit.
  Triggers: covey, .localhost site, local dev server, "site won't load",
  php-fpm, local php version, mailpit, laravel local environment, ~/Covey.
---

# Covey Skill

Covey is a local PHP development environment: a directory in `~/Covey` is served
at `https://<name>.localhost` with automatic TLS.

## Scope boundary (important)

Covey manages **the platform**: web server, PHP versions, and local services.
Covey **never modifies files inside a project**. If a problem is app-level
(`.env`, `APP_KEY`, `storage/` permissions, stale `vendor/`), report it to the
user - do not expect covey to fix it, and do not use covey commands to try.

## Commands

    covey install            render config, link systemd units and this skill
    covey start|stop|restart bring the environment up or down
    covey sync               regenerate site config from ~/Covey, then reload
    covey reload             reload the web server config
    covey status             show unit state
    covey doctor [--json]    check the platform and every site
    covey sites              list sites, their PHP version and URLs
    covey php [list|install <tag>|configure <tag>]
    covey services [up|down|status|logs]
    covey db [list|create <name>|drop <name>|shell]
    covey logs [caddy|php]   tail logs

## How serving works

- A directory `~/Covey/foo` is served at `https://foo.localhost`.
- If `foo/public/index.php` exists, the document root is `foo/public`
  (framework layout). Otherwise it is `foo` itself.
- Site config is **generated**: `covey sync` writes one Caddy block per site.
  A systemd path unit (`covey-sync.path`) watches `~/Covey` and runs sync
  automatically, so `mkdir ~/Covey/foo` is normally enough.
- Each site gets its own single-name certificate. A wildcard `*.localhost`
  cert cannot be used: TLS clients reject a wildcard with only one label
  after it.

## PHP version selection

Each site resolves to a PHP version, in this order:

1. **`.covey` in the site directory** - an explicit pin: `php = 8.3`
2. **`composer.json` `require.php`** - the constraint is resolved against the
   installed providers (`^`, `~`, `>=`, `X.Y.*` and `||` are supported)
3. **The default** (currently 8.5)

Policy: if the default version already satisfies the constraint, the default is
kept, so most sites share one pool. `.covey` is the escape hatch for "this
project must stay on 8.3 even though composer would allow newer".

Only providers listed in the `PROVIDERS` table in `bin/covey` can be selected.
Installed providers today: 8.5 (`php`), 8.3 (`php-legacy`). Install another
with `covey php install <tag>`.

Each version gets its own FPM pool (`covey-fpm@85`, `covey-fpm@83`), started
automatically when some site resolves to it.

**Changing `.covey` or `composer.json` requires `covey sync`.** The path unit
watches only the top level of `~/Covey`, so it catches new and removed sites
but not edits inside one.

If no installed PHP satisfies a constraint, covey warns and falls back to the
default rather than refusing to serve. The warning names the site. When sync
runs from the path unit these warnings go to the journal:
`journalctl --user -u covey-sync.service`.

## PHP extensions

Arch ships most PHP extensions as `.so` files but **enables almost none of
them**, and the extension packages (`php-redis`, `php-igbinary`) ship their
`.ini` with the `extension=` line commented out. A stock Arch PHP therefore
has no `pdo_mysql`, so a Laravel app cannot reach MySQL at all.

`covey php configure <tag>` fixes this per provider: it installs the extension
packages and writes a managed `conf.d/covey.ini` enabling:

    iconv bcmath exif intl mysqli pdo_mysql sqlite3 pdo_sqlite
    gd sodium igbinary redis

`sqlite3`/`pdo_sqlite` matter because Laravel 11+ defaults to SQLite, and
`iconv` because common packages require it; Arch ships neither enabled.

Beyond this fixed set, `covey doctor` also runs `composer check-platform-reqs`
per site, so an extension a *project* needs but covey does not ship is
reported as `platform_reqs_missing` rather than silently 500-ing.

`igbinary` must load before `redis`; covey's single managed file guarantees
that ordering. The file lives at `/etc/php/conf.d/covey.ini` (8.5) or
`/etc/php-legacy/conf.d/covey.ini` (8.3) and needs root to write, so
`configure` uses sudo. It is **not** run automatically.

If a site reports "could not find driver" or PDO errors, this is almost
certainly the cause: run `covey php configure <tag>` for the version that
site resolves to.

## Services

MySQL (MariaDB), Redis and Mailpit run as a Docker Compose stack managed by
`covey-services.service`. Everything binds to **loopback only**.

Credentials are deliberately chosen so a stock Laravel `.env` works with no
edits:

| Service | Host / port          | Credentials        |
|---------|----------------------|--------------------|
| MySQL   | `127.0.0.1:3306`     | user `root`, empty password |
| Redis   | `127.0.0.1:6379`     | no auth            |
| Mailpit | SMTP `127.0.0.1:1025`, UI <http://127.0.0.1:8025> | none |

Laravel's default `DB_*` and `REDIS_*` values already match. Mail needs
`MAIL_MAILER=smtp`, `MAIL_HOST=127.0.0.1`, `MAIL_PORT=1025`.

Databases are **not** created automatically - creating one is an explicit
action: `covey db create <name>`.

## Bar module

covey ships an omarchy-shell bar widget (`share/omarchy/covey/`), symlinked
into `~/.config/omarchy/plugins/covey` by `covey install`. Enable it with
`omarchy plugin enable covey`.

It polls `covey doctor --json --cached` and shows one icon: normal while every
check passes, `Color.urgent` when any fails. The tooltip lists each failing
check with its fix command; clicking opens `covey doctor` in a floating
terminal. It is a **renderer over the same JSON model** the CLI and agents
read - not a second source of truth.

Refresh interval is configurable in the widget's settings (default 15s).
Because results are cached, polling is cheap.

## Architecture

Everything runs as **user** systemd units grouped under `covey.target`:

    covey.target
      covey-caddy.service     web server (Caddy)
      covey-fpm@<ver>.service PHP-FPM pool, one instance per PHP version
      covey-sync.path         watches ~/Covey, triggers covey-sync.service
    covey-services.service  docker compose stack (mysql, redis, mailpit)

Running as the user (not `http`) is deliberate: the FPM pool reads `~/Covey`
with no ACL or permission workarounds.

## Topic guides

- [`troubleshooting.md`](troubleshooting.md) - `covey doctor`, the JSON check
  contract, and every `problem` code with its fix. **Read this before
  diagnosing any covey problem.**

## Troubleshooting

Run `covey doctor` first - it checks the platform and every site and prints
the fix for anything broken. `covey doctor --json` gives the same result as
structured data (exit 0 = all passed, 1 = something failed); see
[`troubleshooting.md`](troubleshooting.md) for the schema and problem codes.

Then `covey status` and `covey logs caddy`.

- **First request to a brand-new site fails TLS**, then succeeds: normal.
  The certificate is issued on first handshake (~1s). Retry.
- **Site 404s or shows a directory listing**: check whether the project has
  `public/index.php`; docroot selection depends on it.
- **New directory not served**: confirm `covey-sync.path` is active, or run
  `covey sync` manually. Names that are not valid DNS labels are skipped.
- **Database connection refused**: check `covey services status`; the stack may
  be down or still starting. MySQL has a healthcheck, so `covey services up`
  waits for it to be ready.
- **Site is on the wrong PHP version**: run `covey sites` to see what it
  resolved to, and `covey php list` to see what is installed. Edits to
  `.covey` or `composer.json` need a manual `covey sync`.
