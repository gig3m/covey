# Hacking on covey

A local PHP development environment for Linux. A directory in `~/Covey` is
served at `https://<name>.localhost`. See [`README.md`](../README.md) for user
docs and [`agents/skills/covey/`](../agents/skills/covey/) for the
operator-facing skill.

**This file is about working ON covey.** The skill is about USING it.

For *why* these decisions were made — including the approaches that were
rejected (Valet Linux Plus, DDEV, mise-php, containerised FPM) and what they
cost — read [`DESIGN.md`](DESIGN.md). Read it before proposing an
architectural change; the alternatives look attractive again every time you
forget why they were turned down.

## The charter (settled, do not drift)

covey manages **the platform**. It never modifies files inside a project.

- **In:** serving, TLS, PHP versions and extensions, MySQL/Redis/Mailpit,
  databases on request, and checks for all of the above.
- **Out:** `.env`, `APP_KEY`, `storage/` permissions, `composer install`,
  `vendor/`, npm/asset builds, queue workers, schedulers.

Scope was set as "covey does Herd things, no more." Two consequences that have
already been litigated: databases are **not** auto-created when a site appears
(that would beat Herd, which is out of scope), and app-level failures are
*reported*, never fixed. This boundary doubles as the agent safety boundary —
covey exposes no path to write inside a project.

Reading project metadata (`composer.json`, `.covey`) is **in** scope; it is how
covey decides what platform to provide. Writing project files is not.

## Architecture invariants

**`share/php/core.php` is the single source of truth** for the provider
registry, PHP version resolution, and the check model. `bin/covey` is a thin
shell wrapper that calls it. Resolution once lived in bash and would have
drifted from doctor's view of the same sites — do not reimplement it there.

**`SERVICES` in `core.php` is the service registry**: ports, credentials, the
`.env` lines, URLs. Doctor's port checks and `covey status --json` both read
it, and image tags are parsed from the compose file rather than repeated. The
compose file still binds the ports, so a port change is two edits — do not add
a third copy (in the widget, say).

**`share/providers.tsv` and `share/extensions.txt` are shared data**, read by
both the shell and PHP sides. Adding a PHP version is one row in the TSV.

**One JSON model, three renderers.** `covey doctor` produces the model;
terminal output, `--json`, and the omarchy bar widget all render it. The bar is
a renderer, never a second source of truth.

**A stopped stack is a state, not a failure.** `covey doctor` derives `state`
(`up` / `degraded` / `down`) from whether `covey.target` is active, and while it
is down runs only the *static* checks, skipping caddy, pools, service ports,
HTTPS and database existence. Without this, `covey down` produced eight red
failures each carrying a `fix.cmd` telling an agent to start what the user had
just stopped. Derive the state from systemd, never from a marker file - a marker
is a second source of truth and will drift.

**A disabled site is a state, not a failure** — the per-site twin of the rule
above. `covey site down <name>` records the name in `~/.config/covey/disabled`
and the site then emits no check that can fail, so doctor can go green again
with a half-finished project checked out. This is declared *intent*, not an
observation, which is why it lives in a file and does not contradict "derive
state from systemd": a site is a Caddy block, not a unit, so there is nothing
to derive it from, and it cannot live in the generated Caddyfile (sync rewrites
it) or the project's `.covey` (covey never writes inside a project). See
`DESIGN.md` §10.

**`~/Covey` is enumerated in exactly one place**: `core.php sites`, which emits
name/dir/tag/enabled/kind. `cmd_sync` and `cmd_sites` consume it. It was
previously globbed in three places with the name regex copy-pasted into each —
do not add a fourth.

**The `fix` / `hint` contract.** A failing check carries `fix.cmd` only when it
is a runnable command. When nothing can fix it automatically, it carries `hint`
(prose) and no `fix`. An agent must be able to execute any `fix.cmd` blindly.
Branch on `problem` (stable code), never on `detail` (human text).

**Everything is a user systemd unit under `covey.target`.** No root daemons.
FPM runs as the user so it reads `~/Covey` without ACLs.

**Dev install is a symlink**: `~/.local/share/covey` → this checkout. Editing
the project takes effect immediately; moving or deleting it breaks the running
environment.

## Hard-won facts (rediscovering these costs hours)

- **A wildcard `*.localhost` certificate cannot work.** TLS clients reject a
  wildcard with only one label after it (`*.localhost` is treated like `*.com`);
  Caddy warns about this itself. This is *why* site config is generated
  per-site rather than one wildcard block. On-demand TLS does not help — Caddy
  still serves the wildcard because it is a configured site name. The generated
  block also carries the site's FPM socket, which is what makes per-site PHP
  versions work.
- **`caddy trust` only writes the system store**, and short-circuits once the
  CA is there. Chrome and Firefox on Linux read their own NSS database
  (`~/.pki/nssdb`), which may not exist at all. Result: trusted by curl,
  rejected by every browser — invisible to command-line testing. `covey trust`
  does both halves. Browsers read NSS at startup, so they need a restart.
- **Arch enables almost no PHP extensions.** Modules ship as `.so` and are off;
  `php-redis` and `php-igbinary` ship their `.ini` with `extension=` commented
  out. `igbinary` must load before `redis`. Stock Arch PHP has no `pdo_mysql`
  and no sqlite module at all — and Laravel 11+ defaults to SQLite.
- **covey's extension list is fixed, so it cannot see what a project needs.**
  That is why doctor also runs `composer check-platform-reqs` per site.
- **User services cannot bind :80/:443** until
  `net.ipv4.ip_unprivileged_port_start=80`. `covey install` warns; it does not
  set it (that needs root).
- **`After=network-online.target` is inert in the user manager.** The target is
  not even loaded in the user instance (`systemctl --user is-active
  network-online.target` → inactive, 0 units listed), so ordering on it is a
  no-op that *looks* like a fix. On the machine covey was built on, the system side was no better:
  `network-online.target` reports active while
  `NetworkManager-wait-online.service` is masked, so nothing ever waited. This
  bit `covey-services.service`, which starts at login and needs DNS when an
  image must be pulled: it failed once at boot and stayed failed. The fix is a
  **retry** (`Restart=on-failure` + `RestartSec`, bounded by
  `StartLimitBurst`), not an ordering dependency. `Restart=` *is* honoured for
  `Type=oneshot` — verified; only `always`/`on-success` are rejected there.
- **Reload FPM pools, never restart them.** `covey-fpm@` has
  `ExecReload=kill -USR2`: php-fpm re-execs in place (same PID) with the
  listening socket inherited, so there is no 502 window. Restarting instead
  both drops requests (Type=simple returns before the new master listens) and
  counts toward the unit's start limit - five quick `covey php set` calls hit
  `StartLimitBurst`, the pool went `failed`, and every site 502'd until
  `systemctl --user reset-failed`. `ensure_php_pool` reloads only when the
  rendered config changed, then waits for the socket to accept.
- **`covey-sync.path` watches only the top level of `~/Covey`.** New and removed
  sites are caught; edits to a site's `.covey` or `composer.json` are not. Run
  `covey sync`.
- **The bar widget instantiates once per monitor.** Only the first IPC handler
  registers (the shell logs a benign duplicate-handler warning). After changing
  the widget's IPC surface, `omarchy restart shell` — a plugin rescan alone can
  keep the stale handler.
- **`BarWidget.broadcast(method)` calls the method with no arguments**, on every
  monitor's instance. So a broadcast target must take none, and anything with a
  side effect (running `covey up`) must happen *once*, outside the broadcast —
  otherwise a two-monitor bar runs it twice.
- **A QML property-assignment type error aborts the rest of the function.**
  `root.stackState = st`, where `st` had been shadowed by a later `var st`, threw
  `Cannot assign QJSValue to QString`, and every assignment after it — including
  `root.sites` — silently never ran, so the flyout showed "No sites yet" against
  a perfectly good doctor model on disk. `var` is function-scoped in QML's JS: a
  loop variable further down the function is the *same* variable. Check
  `journalctl --user | grep BarWidget` when the widget renders stale nonsense.
- **`docker stats --no-stream` costs ~2s per call.** That is why container memory
  is measured only behind `--resources`, never on the path the bar polls.
  systemd's `MemoryCurrent` is a free property read, and one `systemctl show`
  covers every unit at once.
- **A QML inline `component` does not share the file's id scope.** Inside
  `component Foo: Item {}`, `root` and every other id in the file are
  unreachable, so anything that needs them belongs in a delegate, not a
  component. The flyout's site rows are a single Repeater delegate for this
  reason; `LinkText` is an inline component only because it needs no ids.
- **Bar styling must follow the shell**: bind `font.family` to the bar's
  `fontFamily`, falling back to `Style.font.family` (the fontconfig `monospace`
  alias). Never bind to `Style.font.resolvedFamily` — that exists only for
  *displaying* which family is drawing.

## Verifying changes

    covey doctor            # exit 0 = healthy, 1 = something failed
    covey doctor --json     # the model itself
    covey status            # stack state, unit state, memory in use
    covey down && covey doctor   # must read as stopped, exit 0, no fixes offered

Test failure paths, not just the happy path — the whole point of covey is that
breakage is legible. Cheap ways to force one:

    mkdir ~/Covey/x && printf 'database = nope\n' > ~/Covey/x/.covey  # database_missing
    printf 'php = 8.2\n' > ~/Covey/x/.covey                           # no_provider
    docker compose -f share/compose/covey.yaml stop redis             # service_down

For the bar widget there is no substitute for looking at it. `grim -o <output>`
captures one monitor (check `hyprctl monitors -j` for names).
`omarchy-shell covey toggle` opens the flyout without a mouse, and
`omarchy-shell shell summon covey '{"tab":"php"}'` the settings window (the
plugin's `overlay` entry, `Settings.qml`). The overlay takes exclusive keyboard
focus, so `wtype 2` / `wtype -k Escape` drive it. With no pointer-synthesis
tool installed, exercise a click path by adding a temporary `Timer` that calls
the same function the click does, restart the shell, capture, and remove it.

## Deliberately not done

- No auto-provisioning of databases (out of charter).
- No MCP server — a skill plus a JSON CLI is the pattern omarchy uses, and a
  daemon protocol would exceed it.
- No `covey uninstall`. covey writes to ~8 locations outside the project, three
  root-owned; there is currently no teardown. This is a known gap.
- PHP providers are limited to verified rows in `providers.tsv` (8.5, 8.3).
  AUR has `php74`–`php84` if a project ever needs one; shipping unverified
  binary paths would create exactly the "why isn't it working" problem covey
  exists to remove.
