# Design notes

Why covey is shaped the way it is. [`HACKING.md`](HACKING.md) states the invariants; this
records the reasoning behind them, including the options that were rejected and
why. Written down because the alternatives look attractive again every time you
forget what they cost.

---

## 1. What Herd actually does

covey replicates a mechanism, not a product. Herd is a GUI around the design
Laravel Valet pioneered, and it has five moving parts:

1. **Bundled PHP binaries** — self-contained builds, several versions, in
   Herd's app-support directory. It never touches system PHP. Each version has
   its own FPM pool on its own socket; "switching version" means pointing a
   site at a different socket.
2. **One nginx instance** on :80/:443 with a *catch-all* vhost — not one vhost
   per site.
3. **dnsmasq** answering `*.test` → `127.0.0.1`.
4. **The part that makes `park` feel magic** — nginx hands every request to
   Valet's PHP *driver* layer, which reads the `Host` header, strips `.test`,
   finds the matching subdirectory, then sniffs the project type (Laravel →
   `public/index.php`, WordPress, Statamic, plain PHP) to pick the document
   root. Nothing is registered anywhere; the lookup happens per request. That
   is why a new folder just works.
5. **`herd secure`** — a cert from a local CA trusted in the system keychain.

Herd Pro adds MySQL/Postgres/Redis/Mailpit as managed processes, plus log and
dump viewers.

**Only one piece is genuinely macOS-only:** step 3's wiring. macOS has
`/etc/resolver/test`, a file that delegates an entire TLD to a nameserver.
Linux has no per-TLD hook. Everything else has a direct Linux equivalent.

## 2. `.localhost`, not `.test`

`systemd-resolved` already synthesises loopback for anything under `.localhost`
(RFC 6761), and Chrome and Firefox do too. Verified on the development machine
before committing to it:

    anything.localhost  → 127.0.0.1   ✓ zero config
    foo.test            → not found

Choosing `.localhost` **deletes the entire DNS layer**: no dnsmasq, no
`/etc/hosts` edits, no `systemd-resolved` drop-in, and nothing to break when
the network changes. That last point was not hypothetical — the development machine runs
Tailscale MagicDNS, exactly the kind of thing a hand-rolled dnsmasq fights.

Cost: `.test` muscle memory from Herd. Accepted deliberately.

Had `.test` been required, the path was dnsmasq on `127.0.0.1:5353` plus a
`resolved` drop-in routing `~test` to it. Workable, but one more thing that can
break, for a cosmetic gain.

## 3. Rejected approaches

### Valet Linux Plus

The literal port — real `park` / `link` / `secure` / `isolate` commands, closest
to Herd muscle memory.

**Rejected because** it wants to own nginx and dnsmasq itself, which is what
would collide with `systemd-resolved` and Tailscale on the development machine. Taking a
tool that manages system DNS onto a box where two other things already do is
buying the exact fragility `.localhost` was chosen to avoid.

### DDEV

Genuinely strong, and it was under-sold on the first pass. Purpose-built for
the pinning problem: `php_version` per project, bundled databases, Mailpit,
automatic trusted TLS via mkcert, a router container doing the same hostname
catch-all, and `ddev composer` / `ddev artisan` wrappers already written. All
the gravy, maintained by someone else.

**Rejected because** it costs `ddev config` per project — not zero-touch
`mkdir` — a `.ddev/` directory in each repo, containers per project rather than
one shared stack, and `.ddev.site` domains. The stated core value was "make a
dir, it gets served." DDEV trades exactly that away.

This remains the correct answer for anyone who does not care about the
zero-touch property. It is less code to own.

### mise for PHP

Very attractive: mise was already the version manager on the development machine, and
per-directory `.mise.toml` would have given per-site PHP versions for free.

**Rejected because** both backends (`vfox:jdx/vfox-php`,
`asdf:mise-plugins/asdf-php`) **build from source**. That means 5–15 minutes
per version, a pile of build dependencies, and — the real killer — extensions
fixed at compile time via `PHP_CONFIGURE_OPTIONS`. Wanting `intl` or `redis`
later means rebuilding the whole interpreter. This is the well-worn `asdf-php`
pain that people generally abandon. It pins beautifully and is miserable to
live with.

### Containerised PHP-FPM

Philosophically closest to what Herd actually does: pinned images, arbitrary
versions side by side, extensions baked in, immune to `pacman`. It would also
have collapsed everything but the web server into one Docker stack.

**Rejected because** the CLI becomes `docker exec`. `artisan` and `composer`
need wrapping, the editor's language server wants a real local `php`, and bind
mounts bring UID-mapping friction. A normal `php` on `PATH` is a large part of
what makes Herd pleasant day to day.

## 4. The pinning reframe

The stated worry was "PHP moving out from under an old package with breaking
changes" — a real risk with rolling-release Arch.

Checking the actual projects changed the shape of the problem:

| repo | `require.php` | Laravel |
|---|---|---|
| app A | `^8.2` | ^12.0 |
| app B | `^8.3` | ^13.0 |
| app C | `^8.2` | ^12.0 |

All satisfied by 8.5 today. So this is **not a version-spread problem** —
nothing needs 7.4 or 8.0 — it is a version-**drift** problem: `^8.2` means
Composer will not stop you, but a transitive dependency hitting a deprecation
after some unrelated `pacman -Syu` will.

That is much cheaper to solve. You do not need per-site isolation. You need
**one PHP that only moves when you decide it moves.**

And the escalation ladder turned out deeper than assumed. `php` (8.5) and
`php-legacy` (8.3) co-install cleanly — checked the conflict metadata, not the
docs: `php-legacy-fpm` conflicts with nothing. AUR carries `php74` through
`php84`. So "use pacman until we can't" essentially never reaches "can't", and
Docker stops being a necessary fallback tier at all.

## 5. `.covey`: derive first

The `.covey` manifest was the right instinct, with one refinement that matters.

**If `.covey` restates `require.php`, it becomes a second source of truth that
silently drifts from composer.json** — adding a new class of "why isn't it
working," which is the exact thing covey exists to remove. So resolution is:

    .covey  →  composer.json require.php  →  default

and `.covey` earns its place only for what Composer genuinely cannot express:
which services to bring up, the database name, a version override that
*contradicts* composer ("stay on 8.3 even though `^8.2` allows newer").

Consequence: **most projects need no `.covey` at all**, which preserves
mkdir-and-go. The policy that the default wins when it already satisfies the
constraint follows from the same idea — fewer pools, fewer moving parts, and
the file only appears when someone has a real reason.

## 6. Legibility over isolation

The pivotal reframing, and it came from the user: the biggest problem with
local environments is *knowing why something isn't working*.

Isolation **prevents** drift, at the cost of weight (containers, pinned
toolchains, per-project config). Detection **reports** it. Given that
diagnosability was the actual pain, covey aims at legibility: every check
resolves to a cause *and a command*.

This is why `covey doctor` is the centrepiece rather than an afterthought, and
why the `fix` / `hint` distinction is enforced — a `fix.cmd` an agent cannot
blindly execute is worse than no `fix` at all.

It is also why `composer check-platform-reqs` is reused rather than
reimplemented: it is authoritative, and it knows transitive requirements the
project's own `composer.json` never mentions. That check was specified during
design, *not built* in the first pass, and then immediately proved necessary
the first time a real application was cloned.

## 7. One model, three renderers

The payoff of the check layer, and the reason agent support was nearly free.

    covey doctor  →  JSON model  →  terminal (human)
                                 →  bar widget (glanceable)
                                 →  agent (--json)

The bar module and an agent want the *same thing*: what is broken, why, and the
command that fixes it. So the work done for the status bar was already the
agent interface. Nothing was bolted on.

The settings window added later is a fourth renderer, not a second model: it
draws `covey doctor --json` for whether things are right and `covey status
--json` for what covey provides (services, PHP providers, settings), and each of
its buttons runs a `covey` command.

Two constraints fall out of this:

- **Human output must be a rendering of the JSON model**, never a separate code
  path, or the two drift and the agent starts getting lies.
- **The checks must be cached.** A bar ticking every second cannot shell out to
  `composer` per site. Cached: 19ms, cold: 172ms.

## 8. Agent access follows omarchy

The pattern was copied deliberately rather than invented: the tool owns its own
skill directory and installation symlinks it into the agent's skill path
(`agents/skills/covey` → `~/.claude/skills/covey`), with a `SKILL.md` index and
topic guides loaded on demand.

**No MCP server.** A skill plus a JSON CLI is what omarchy does; adding a daemon
protocol would exceed the pattern being matched.

The scope boundary doubles as the safety boundary for free: covey exposes no
path to modify files inside a project, so an agent driving it can install a PHP
version or start a service but cannot wander into source.

## 9. When a constraint improved the design

Worth recording, because it looked like a setback.

The original plan was one wildcard `*.localhost` server block plus a `map`
directive to pick the FPM socket per host — with an open question about whether
`php_fastcgi` accepts a placeholder upstream.

Then the wildcard turned out to be impossible: TLS clients reject a wildcard
with only one label after it. On-demand issuance did not help, because Caddy
still serves the wildcard for a configured site name.

Generating one block per site fixed the certificate problem **and** removed the
open question entirely — each generated block simply carries its own socket as
a literal. The constraint produced a simpler design than the one it destroyed.

## 10. Per-site up/down, and why a file here is not a marker file

`covey down` was all or nothing, which left one real gap: doctor is the
centrepiece (§6), and its value collapses if it is permanently red. With
seventeen sites checked out, several half-finished, `ok` was false and the bar
was urgent more or less always — so the signal stopped meaning anything. The
fix is not better checks; it is being able to say "not this one, not today."

The obvious objection is that `HACKING.md` forbids exactly this: *derive state
from systemd, never from a marker file.* The distinction that resolves it:

- The **stack's** up/down is an **observation**. `covey.target` already knows
  it, so a file recording it too is a second copy that will drift. Forbidden,
  and rightly.
- A **site's** up/down is **declared intent**. Nothing else on the machine
  knows it, and nothing can: a site is a generated Caddy block, not a unit, so
  there is no unit state to read. It cannot be kept in the generated Caddyfile
  either, because `covey sync` rewrites that from scratch every run — the state
  would erase itself. And it cannot go in the project's `.covey`, because covey
  never writes inside a project — the charter.

That leaves one covey-owned file, `~/.config/covey/disabled`. It is *input* to
the model, not a cached copy of a fact something else owns, which is precisely
what keeps it from being the failure mode the rule was written about.

**The memory story is smaller than it looks, and saying so matters.** Pools are
per PHP version, shared by every site on that version. Disabling one of a dozen
8.5 sites frees nothing at all. It frees a pool (~25 MiB) only when it is the
last site on a version — which is why `covey sync` gained the ability to *stop*
a pool no enabled site asks for, something it previously never did (it only
ever called `add-wants` and started them, so pools accumulated for the life of
the login session). Sold as a memory feature this would disappoint; the honest
pitch is that it is a legibility feature that occasionally reclaims a pool.

Two consequences fell out, both reusing decisions already made:

- **A disabled site emits no check that can fail**, exactly as a stopped stack
  runs no runtime checks. Same rule, same reason: off on purpose is a state,
  not a failure.
- **It still gets a Caddy block**, answering 503 with the command that undoes
  it. Removing the block was the tidier implementation and the worse product —
  it produces a bare TLS error, indistinguishable from a broken site, which is
  the exact failure shape §11 records as the worst available.

It also forced a cleanup that was overdue: `~/Covey` was being enumerated in
*three* places — `sites()` in core.php, the loop in `cmd_sync`, and `cmd_sites`
— with the site-name regex copy-pasted into each. A disabled list would have
been a fourth thing to keep in step. They now all consume `core.php sites`,
which is what the "core.php is the single source of truth" invariant asked for
in the first place.

**Solo came later, and its one real decision was what "undo" means.** With
eleven sites checked out, the switch you actually want is "only this one
today". The tempting undo is "turn everything back on", which silently
re-enables the half-finished project you had switched off on purpose, the
exact case per-site down exists for. So `covey site solo` saves the list that
was off before it, in `~/.config/covey/solo`, and `covey site restore` puts
that list back. It is the same kind of file as `disabled`: declared intent,
input to the model, nothing else on the machine knows it.

## 11. What running a real application changed

The design was validated by cloning an actual Laravel 12 app, not by reasoning.
Three defects surfaced within minutes, all invisible from the armchair:

- **No sqlite at all.** Laravel 11+ defaults to `DB_CONNECTION=sqlite`, and Arch
  ships no sqlite module. The stock database driver did not work.
- **`ext-iconv` missing**, required by common packages; Arch ships `iconv.so`
  and leaves it off. `composer install` failed outright.
- **HTTPS was trusted by curl and rejected by every browser**, because
  `caddy trust` writes only the system store while browsers read NSS. The worst
  failure shape available: invisible to exactly the tooling used to verify it.

The lesson is the one worth keeping: a local environment is validated by a real
application, and specifically by looking at it in a browser. Command-line
success is not the same as working.
