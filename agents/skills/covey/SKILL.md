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
    covey sites              list sites and their URLs
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
