# Covey troubleshooting

Start with `covey doctor`. It checks the platform and every site, and every
failure carries either a `fix` (a command you can run) or a `hint` (no
automatic fix exists).

For programmatic use: `covey doctor --json`. Exit code is `0` when everything
passes and `1` when anything fails.

## The JSON contract

    {
      "ok": false,
      "state": "up",            // up | degraded | down - check this first
      "solo": null,             // a site name while `covey site solo` is in effect
      "resources": {            // memory the stack is using
        "units":      [ {"name": "covey-caddy.service", "bytes": 88088576}, ... ],
        "containers": null,     // only measured with --resources (costs ~2s)
        "bytes": 170000000      // total of what was measured
      },
      "platform": [ <check>, ... ],
      "sites": [
        { "name": "pub", "url": "https://pub.localhost", "path": "...",
          "enabled": true,        // false = `covey site down`; emits no failing check
      "share": null,          // or {state, url, port, tunnel} while `covey share`d
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
changed something and need current truth. `--resources` additionally samples
container memory, which costs ~2s - leave it off unless you need the figure.

## `state` comes before the checks

`state` says whether the stack is meant to be running:

| `state` | Meaning | What to do |
|---|---|---|
| `up` | `covey.target` is active and everything under it is running | Read the checks normally |
| `degraded` | The target is active but caddy, a pool, or the services are not | A real failure - follow the `fix` |
| `down` | The target is stopped, i.e. someone ran `covey down` | Run `covey up`. Do not diagnose. |

While `state` is `down`, doctor runs only the **static** checks - PHP providers,
extensions, browser trust, and each project's composer platform requirements -
and skips the runtime ones (caddy, FPM pools, service ports, HTTPS, database
existence). It exits 0, because a stopped stack is not a broken one.

So a site that "is not loading" while `state` is `down` needs `covey up`, not a
diagnosis. Check `state` before reading `ok`.

## A disabled site is not a failure

`"enabled": false` means someone ran `covey site down <name>`. Such a site
carries a single passing `site` check reading `disabled (covey site up <name>)`
and **nothing that can fail** - the same rule that keeps a stopped stack from
reporting eight red checks. Do not "fix" it: bringing it back is the user's
call, and `covey site up <name>` is the only thing that does so.

It still answers over HTTPS with a 503 explaining itself, so a disabled site
and a broken one never look alike.

## Problem codes

| `problem` | Meaning | Fix |
|---|---|---|
| `caddy_inactive` | Web server not running | `covey up` |
| `pool_inactive` | FPM pool for a needed version is down | `covey up` |
| `provider_not_installed` | A site wants a PHP covey knows but hasn't installed | `covey php install <tag>` (root) |
| `no_provider` | A site wants a PHP covey has no provider row for | none - add a row to `share/providers.tsv` |
| `extensions_missing` | Extensions are not enabled for that provider | `covey php configure <tag>` (root) |
| `constraint_unsatisfiable` | No installed PHP satisfies `require.php` | `covey php list`, then install one |
| `docker_unavailable` | Docker is not responding | `sudo systemctl start docker` |
| `service_down` | Nothing listening on a service port | `covey services up` |
| `tls_untrusted` | Cert is not trusted by the system store | `covey trust` (root) |
| `ca_untrusted_by_browsers` | Local CA missing from the browser (NSS) store | `covey trust` (root) |
| `http_failed` | Request to the site failed | `covey logs caddy` |
| `http_5xx` | Site returned 5xx - usually an application error | `covey logs php` |
| `database_missing` | `.covey` declares a database that does not exist | `covey db create <name>` |
| `ini_upload_exceeds_post` | `upload_max_filesize` > `post_max_size`; larger uploads arrive empty | `covey php set post_max_size <size>` |
| `share_failed` | The site's tunnel unit crashed and gave up | `covey unshare <site>` clears it. Re-sharing republishes the site - only on the user's say-so |
| `php_ini_invalid` | A hand-edited line in `~/.config/covey/php.ini` was ignored | `hint` only - edit or delete the line |
| `database_name_invalid` | `.covey`'s `database =` is not a plain identifier | `hint` only - fixing `.covey` is the user's call |
| `reserved_name` | A directory in `~/Covey` uses a name covey serves itself (`mail`) and is not served | `hint` only - renaming a project directory is the user's call |
| `platform_reqs_missing` | The project's own dependencies need an extension that is not loaded | `covey php configure <tag>` if covey manages it; otherwise a `hint` naming the extension |

## Things that are not covey's problem

Covey checks the **platform**. If `covey doctor` passes and the site still
misbehaves, the cause is app-level and outside covey's scope: missing `.env`
or `APP_KEY`, unwritable `storage/`, stale `vendor/`, or a framework error.
Report these to the user; do not expect a covey command to fix them.

## Common situations

**Nothing on `.localhost` responds and `covey doctor` says all checks passed.**
Look at `state`. If it is `down`, covey is stopped - `covey up`. Doctor is not
wrong; it skipped the runtime checks on purpose.

**A brand-new site's first request fails TLS, then works.** Normal - the
certificate is issued on the first handshake. Retry once.

**The site works in curl but the browser shows a certificate error.** Chrome
and Firefox on Linux read their own NSS database (`~/.pki/nssdb`), not the
system trust store, and `caddy trust` only writes the system store. Run
`covey trust`, then **restart the browser** - it reads NSS at startup, so an
already-running browser keeps rejecting the certificate until restarted.

**`Vite manifest not found`.** Assets are not built. App-level, not covey:
run `npm install && npm run build` in the project.

**`could not find driver` / PDO errors.** The provider that site resolves to
has no `pdo_mysql`. Run `covey php configure <tag>` for that tag - note it may
be a different tag than the default if the site pins a version.

**Changed `.covey` or `composer.json` but nothing happened.** The path unit
watches only the top level of `~/Covey`, so it sees new and removed sites but
not edits inside one. Run `covey sync`.
