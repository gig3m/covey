# Covey troubleshooting

Start with `covey doctor`. It checks the platform and every site, and every
failure carries either a `fix` (a command you can run) or a `hint` (no
automatic fix exists).

For programmatic use: `covey doctor --json`. Exit code is `0` when everything
passes and `1` when anything fails.

## The JSON contract

    {
      "ok": false,
      "platform": [ <check>, ... ],
      "sites": [
        { "name": "pub", "url": "https://pub.localhost", "path": "...",
          "php": {"tag":"83","series":"8.3","resolved":"8.3.33",
                  "required":"^8.3","source":"composer.json"},
          "checks": [ <check>, ... ] }
      ]
    }

A `<check>` is:

    { "check": "extensions-8.3", "ok": false,
      "problem": "extensions_missing",          // stable code, safe to branch on
      "detail":  "pdo_mysql gd",                // human text, do not parse
      "fix":     {"cmd": "covey php configure 83", "needs_root": true} }

**`fix.cmd` is always a runnable command.** When no command can fix the
problem, the check has no `fix` at all and carries `hint` instead - never
try to execute a `hint`. Branch on `problem`, not on `detail`.

`--cached [ttl]` serves a recent result (default 10s) instead of re-running
the HTTP checks. Use it for polling; use the uncached form when you have just
changed something and need current truth.

## Problem codes

| `problem` | Meaning | Fix |
|---|---|---|
| `caddy_inactive` | Web server not running | `covey start` |
| `pool_inactive` | FPM pool for a needed version is down | `covey start` |
| `provider_not_installed` | A site wants a PHP covey knows but hasn't installed | `covey php install <tag>` (root) |
| `no_provider` | A site wants a PHP covey has no provider row for | none - add a row to `share/providers.tsv` |
| `extensions_missing` | Extensions are not enabled for that provider | `covey php configure <tag>` (root) |
| `constraint_unsatisfiable` | No installed PHP satisfies `require.php` | `covey php list`, then install one |
| `docker_unavailable` | Docker is not responding | `sudo systemctl start docker` |
| `service_down` | Nothing listening on a service port | `covey services up` |
| `tls_untrusted` | Cert is not trusted by the system store | `sudo caddy trust` |
| `http_failed` | Request to the site failed | `covey logs caddy` |
| `http_5xx` | Site returned 5xx - usually an application error | `covey logs php` |
| `database_missing` | `.covey` declares a database that does not exist | `covey db create <name>` |

## Things that are not covey's problem

Covey checks the **platform**. If `covey doctor` passes and the site still
misbehaves, the cause is app-level and outside covey's scope: missing `.env`
or `APP_KEY`, unwritable `storage/`, stale `vendor/`, or a framework error.
Report these to the user; do not expect a covey command to fix them.

## Common situations

**A brand-new site's first request fails TLS, then works.** Normal - the
certificate is issued on the first handshake. Retry once.

**`could not find driver` / PDO errors.** The provider that site resolves to
has no `pdo_mysql`. Run `covey php configure <tag>` for that tag - note it may
be a different tag than the default if the site pins a version.

**Changed `.covey` or `composer.json` but nothing happened.** The path unit
watches only the top level of `~/Covey`, so it sees new and removed sites but
not edits inside one. Run `covey sync`.
