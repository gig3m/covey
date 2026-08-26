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
    covey sites              list sites, their PHP version and URLs
    covey php [list|install] show or install PHP providers
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

## Architecture

Everything runs as **user** systemd units grouped under `covey.target`:

    covey.target
      covey-caddy.service     web server (Caddy)
      covey-fpm@<ver>.service PHP-FPM pool, one instance per PHP version
      covey-sync.path         watches ~/Covey, triggers covey-sync.service

Running as the user (not `http`) is deliberate: the FPM pool reads `~/Covey`
with no ACL or permission workarounds.

## Troubleshooting

Check unit state first: `covey status`, then `covey logs caddy`.

- **First request to a brand-new site fails TLS**, then succeeds: normal.
  The certificate is issued on first handshake (~1s). Retry.
- **Site 404s or shows a directory listing**: check whether the project has
  `public/index.php`; docroot selection depends on it.
- **New directory not served**: confirm `covey-sync.path` is active, or run
  `covey sync` manually. Names that are not valid DNS labels are skipped.
- **Site is on the wrong PHP version**: run `covey sites` to see what it
  resolved to, and `covey php list` to see what is installed. Edits to
  `.covey` or `composer.json` need a manual `covey sync`.
