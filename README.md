# covey

**A local PHP development environment for Linux.** Make a directory, get a
working HTTPS site.

```console
$ mkdir ~/Covey/shop
$ curl https://shop.localhost
```

No `park`, no `link`, no per-project config file, no `ddev config`. A directory
in `~/Covey` is a site. That is the whole interface.

covey is a Linux answer to [Laravel Herd](https://herd.laravel.com/) — same
idea, different machine, and built so that when something *doesn't* work it
tells you why.

---

## Contents

- [Why](#why)
- [Requirements](#requirements)
- [Install](#install)
- [Commands](#commands)
- [How it works](#how-it-works)
- [PHP versions](#php-versions)
- [Services](#services)
- [Up and down](#up-and-down)
- [Per-site up and down](#per-site-up-and-down)
- [Certificates](#certificates)
- [`covey doctor`](#covey-doctor)
- [Status bar](#status-bar)
- [Agents](#agents)
- [Scope](#scope)
- [Contributing](#contributing)
- [License](#license)

---

## Why

Herd is macOS and Windows only. On Linux the usual options each cost something:
Valet Linux Plus wants to own nginx and dnsmasq (which fights `systemd-resolved`
and Tailscale), and DDEV asks for a config step and a container set per project.

covey keeps the property that makes Herd pleasant — **a directory is a site** —
and adds the thing local environments are usually worst at: **saying why a site
is broken.** Every failure `covey doctor` reports carries a machine-readable
cause and the command that fixes it.

It also deliberately does *not* invent a DNS layer. `systemd-resolved` already
resolves every `*.localhost` name to loopback, so covey has no `dnsmasq`, no
`/etc/hosts` edits, and nothing to break when your network changes.

## Requirements

- An Arch-based Linux system (`pacman`)
- A systemd **user** session — everything runs as you, no root daemons
- `systemd-resolved` (for `*.localhost` resolution)
- Docker, for the optional MySQL/PostgreSQL/Redis/Mailpit stack
- `omarchy-shell`, for the optional status-bar widget

## Install

```bash
git clone https://github.com/gig3m/covey.git ~/Projects/covey
ln -s ~/Projects/covey/bin/covey ~/.local/bin/covey

covey php install 85     # PHP + PHP-FPM
covey install            # config, systemd units, agent skill
```

User services cannot bind ports below 1024 by default. Lower the floor once:

```bash
echo 'net.ipv4.ip_unprivileged_port_start=80' | sudo tee /etc/sysctl.d/99-covey.conf
sudo sysctl --system
```

Then enable the extension set, trust the local CA, and start:

```bash
covey php configure 85   # Arch enables almost no PHP extensions by default
covey trust              # local CA into the system *and* browser stores
covey up
```

Verify:

```bash
covey doctor
```

## Commands

| Command | Does |
|---|---|
| `covey install` | Render config, link systemd units and the agent skill |
| `covey up` / `down` / `restart` | Bring the whole stack up or down (`start`/`stop` are aliases) |
| `covey autostart [on\|off]` | Whether the stack starts at login |
| `covey status` | Stack state, unit state, and memory in use |
| `covey doctor [--json]` | Check the platform and every site |
| `covey sites` | List sites, their PHP version and URLs |
| `covey site up\|down <name>` | Take one site in or out of service |
| `covey sync` | Regenerate site config from `~/Covey`, reload |
| `covey php list` | Show PHP providers |
| `covey php install <tag>` | Install a PHP provider |
| `covey php configure <tag>` | Enable the extension set for a provider |
| `covey services [up\|down\|status\|logs]` | The MySQL/PostgreSQL/Redis/Mailpit stack |
| `covey db [list\|create\|drop\|shell]` | Databases |
| `covey trust` | Trust the local CA (system + browser stores) |
| `covey logs [caddy\|php]` | Tail logs |

## How it works

Everything is a **user** systemd unit under one target, so the environment
starts, stops, and reports as a single thing:

```
covey.target
├── covey-caddy.service       Caddy on :80/:443
├── covey-fpm@<ver>.service   one FPM pool per PHP version, started on demand
├── covey-sync.path           watches ~/Covey, regenerates config
└── covey-services.service    docker compose: mysql, postgres, redis, mailpit
```

Running as your user rather than `http` is deliberate: the FPM pool reads
`~/Covey` with no ACLs or permission workarounds.

Site config is **generated**, not wildcard-matched. `covey sync` writes one
Caddy block per site and a path unit runs it when `~/Covey` changes, so `mkdir`
is normally all you do. Generation is not an implementation detail — a wildcard
`*.localhost` certificate *cannot* work, because TLS clients reject a wildcard
with only one label after it (`*.localhost` is treated like `*.com`). Each site
therefore needs its own named block and its own certificate. Usefully, each
generated block also carries that site's FPM socket, which is what makes
per-site PHP versions fall out for free.

Document root is chosen per request shape: if `<site>/public/index.php` exists
it is used (framework layout), otherwise the directory itself is served.

## PHP versions

A site's PHP version resolves in this order:

1. **`.covey`** in the site directory — an explicit pin
2. **`composer.json`** `require.php` — the constraint is resolved against
   installed providers (`^`, `~`, `>=`, `X.Y.*`, `||`)
3. **The default**

If the default already satisfies the constraint, it wins — most sites share one
pool. `.covey` is the escape hatch for *"this project stays on 8.3 even though
composer would allow newer"*, which is the case composer cannot express.

```ini
# ~/Covey/myapp/.covey
php = 8.3
database = myapp
```

Providers live in `share/providers.tsv`; adding a version is one row.
Out of the box: 8.5 (`php`) and 8.3 (`php-legacy`), which coexist cleanly.

### Extensions

Arch ships most PHP extensions as `.so` files and **enables almost none**, and
the `php-redis`/`php-igbinary` packages ship their `.ini` with the
`extension=` line commented out. Stock Arch PHP therefore has no `pdo_mysql`
and no sqlite at all — a Laravel app cannot reach a database.

`covey php configure <tag>` installs the packages and writes one managed
`conf.d/covey.ini` enabling:

```
iconv bcmath gmp exif intl sockets mysqli pdo_mysql sqlite3 pdo_sqlite
pdo_pgsql pgsql gd sodium igbinary redis
```

The single managed file also fixes load order (`igbinary` must precede `redis`).

Because that list is fixed, it cannot know what a *project* needs. So
`covey doctor` additionally runs `composer check-platform-reqs` per site and
reports anything missing.

## Services

MySQL (MariaDB), PostgreSQL, Redis and Mailpit run as one Docker Compose stack,
bound to loopback only. Credentials are chosen so a **stock Laravel `.env` works
unchanged**:

| Service | Address | Credentials |
|---|---|---|
| MySQL | `127.0.0.1:3306` | `root`, empty password |
| PostgreSQL | `127.0.0.1:5432` | `root`, empty password (trust auth) |
| Redis | `127.0.0.1:6379` | none |
| Mailpit | SMTP `127.0.0.1:1025`, UI <http://127.0.0.1:8025> | none |

Databases are created explicitly with `covey db create <name>` — covey does not
provision them behind your back.

## Up and down

The whole stack — Caddy, an FPM pool per PHP version in use, and four
containers — is a few hundred megabytes resident. On a day that is not a PHP
day, hand it back:

```console
$ covey status
STACK    running  (437 MiB)

UNIT                       STATE      MEMORY
covey-caddy.service        active       84 MiB
covey-fpm@85.service       active       43 MiB
covey-fpm@83.service       active       41 MiB
covey-sync.path            active            -
covey-services.service     active            -

CONTAINER                  MEMORY
covey-mysql-1               171 MiB
covey-postgres-1             50 MiB
covey-redis-1                28 MiB
covey-mailpit-1              21 MiB

$ covey down
covey is down
```

`covey up` brings it back. Both are one step because every unit is `PartOf=`
`covey.target`; stopping the target stops the web server, every pool, and the
compose services together.

**A stopped stack is not a broken one.** `covey doctor` derives its `state`
(`up`, `degraded`, `down`) from the target, and while covey is down it runs only
the static checks — what is installed and configured — and skips the runtime
ones. It does not report eight failures, each with a fix telling you to start
what you just stopped:

```console
$ covey doctor
STACK    stopped

PLATFORM
  ok   php-8.5          8.5.9
  ok   extensions-8.5
  ok   browser-trust    local CA in NSS store
...
covey is stopped - run `covey up` to start it
```

`covey down` is **session only**: it stops what is running now and leaves the
login behaviour alone. `covey autostart off` is the separate, persistent choice.

Container memory costs a ~2s `docker stats` sample, so it is measured only where
you asked for it — `covey status` and `covey doctor --json --resources` — never
on the path the bar widget polls.

## Per-site up and down

`covey down` is all or nothing. To take a single site out of service and leave
the rest running:

```console
$ covey site down baseline
covey: baseline is down (covey site up baseline to bring it back)

$ curl -s https://baseline.localhost
covey: baseline is disabled
  bring it back: covey site up baseline

$ covey site up baseline
covey: baseline is up - https://baseline.localhost
```

A disabled site keeps a Caddy block on purpose, so it answers with a 503 that
explains itself. Dropping the block would give a bare TLS error instead — the
kind of unexplained failure covey exists to remove.

**What this is for is quiet, not memory.** FPM pools are per PHP *version* and
shared by every site on it, so switching off one of a dozen sites on 8.5 frees
nothing. What it does do:

- **`covey doctor` stops counting it.** A disabled site emits no check that can
  fail, so doctor going green — and the bar staying calm — means "everything
  I care about today is fine", instead of being permanently red because of a
  half-finished project you are not working on. Same rule as a stopped stack:
  off on purpose is a state, not a failure.
- **It does free a pool when it is the last site on a version.** `covey sync`
  stops any FPM pool no enabled site asks for (~25 MiB each).

The list of what is off lives in `~/.config/covey/disabled`, one name per line.
It is never written into the project — covey does not touch your files.

## Certificates

`covey trust` installs the local CA into **both** the system trust store and the
browser (NSS) store at `~/.pki/nssdb`.

Both halves matter. `caddy trust` writes only the system store, which satisfies
`curl` — while Chrome and Firefox on Linux read NSS and reject the certificate.
That failure is invisible to command-line testing, so `covey doctor` checks it
explicitly. Browsers read NSS at startup: **restart your browser** after running
`covey trust`.

## `covey doctor`

```console
$ covey doctor
PLATFORM
  ok   caddy
  ok   php-8.5          8.5.9
  ok   extensions-8.5
  ok   browser-trust    local CA in NSS store
  ok   mysql            127.0.0.1:3306

myapp  https://myapp.localhost
  ok   php              8.3.33 (from composer.json)
  FAIL database         database 'myapp' does not exist
       fix: covey db create myapp
```

`--json` emits the same model for scripts and agents; `--cached [ttl]` serves a
recent result for polling. Exit code is `0` when everything passes, `1`
otherwise.

Every failing check carries a stable `problem` code and either a runnable
`fix.cmd` or — when nothing can fix it automatically — a `hint`:

```json
{ "check": "extensions-8.3", "ok": false,
  "problem": "extensions_missing",
  "detail": "pdo_mysql gd",
  "fix": { "cmd": "covey php configure 83", "needs_root": true } }
```

Branch on `problem`, never on `detail`. A `hint` is prose — never execute it.
Full code table: [`agents/skills/covey/troubleshooting.md`](agents/skills/covey/troubleshooting.md).

## Status bar

covey ships an [omarchy-shell](https://omarchy.org/) bar widget. `covey install`
links it; enable it with:

```bash
omarchy plugin enable covey
```

One icon: normal while every check passes, red when any fails, dimmed while the
stack is deliberately down. Clicking opens a flyout listing every site under
management with its state — PHP version when healthy, a short problem label when
not — and a row that takes the stack up or down. Clicking a site opens it in the
browser.

```
SITES                          php 8.5, 8.3
● shop                                  8.5
● stack                                 8.5
● needsdb                       no database
Stack running                        Stop →
All checks passed              Full report →
```

`omarchy-shell covey up` and `... down` do the same thing without a mouse.

It is a **renderer over `covey doctor --json`**, not a second source of truth.

## Agents

covey is agent-accessible by design, following the pattern omarchy uses: the
tool owns its documentation and symlinks it into the agent's skill directory.
`covey install` links `agents/skills/covey` into `~/.claude/skills/covey`.

That works because the check layer built for the status bar is exactly what an
agent needs — one JSON model, three renderers (terminal, bar, agent). An agent
can read `covey doctor --json`, branch on `problem`, and run `fix.cmd`.

The scope boundary below doubles as the safety boundary: covey exposes no way
to modify files inside a project, so an agent driving it can install a PHP
version or start a service but cannot wander into your source.

## Scope

covey manages **the platform**. It never modifies files inside a project.

**In:** serving, TLS, PHP versions and extensions, MySQL/PostgreSQL/Redis/Mailpit,
databases on request, and checks for all of the above.

**Out:** `.env`, `APP_KEY`, `storage/` permissions, `composer install`,
`vendor/`, npm and asset builds, queue workers, schedulers.

If `covey doctor` passes and your app still misbehaves, it is app-level — and
covey will tell you that rather than pretend otherwise.

## Contributing

Issues and pull requests welcome.

- `bin/covey` — the CLI (bash)
- `share/php/core.php` — provider registry, version resolution, check model
- `share/providers.tsv`, `share/extensions.txt` — the data both sides read
- `share/systemd/`, `share/caddy/`, `share/compose/` — unit and config templates
- `share/omarchy/covey/` — the bar widget
- `agents/skills/covey/` — the agent skill

Resolution and checks live in `core.php` specifically so the CLI and the doctor
cannot drift into two different views of the same site. Keep it that way.

Two documents worth reading before changing anything:

- [`docs/HACKING.md`](docs/HACKING.md) — the scope charter, architecture invariants, and
  the hard-won facts (why wildcard `*.localhost` certs cannot work, why
  `caddy trust` is not enough, why Arch's PHP has no `pdo_mysql`).
- [`docs/DESIGN.md`](docs/DESIGN.md) — why covey is shaped this way, and which
  alternatives were rejected and at what cost.

## License

MIT — see [LICENSE](LICENSE).
