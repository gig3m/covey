# Contributing to covey

Issues and pull requests are welcome. covey is a small program with a
settled shape; the useful change is usually a smaller one than it first
appears.

## Before you change anything

Read these in order:

1. [docs/HACKING.md](docs/HACKING.md) — the charter, the architecture
   invariants, and the failures that have already been paid for.
2. [docs/DESIGN.md](docs/DESIGN.md) — why the alternatives (Valet Linux
   Plus, DDEV, mise for PHP, containerised FPM) were turned down.

Two rules that catch most proposals:

- covey manages the platform. It never writes files inside a project.
  `.env`, `APP_KEY`, `composer install`, and queue workers are out of scope.
- `share/php/core.php` is the source of truth for which sites exist, which
  PHP they run, and whether they are healthy. The shell, the terminal
  output, and the bar widget render that model. They do not grow a second one.

## Layout

| Path | What it is |
|---|---|
| `bin/covey` | CLI. Thin. Calls `core.php` for anything that must agree with `covey doctor`. |
| `bin/covey-fpm-run` | What the FPM user unit execs. |
| `share/php/core.php` | Provider registry, version resolution, check model. |
| `share/providers.tsv`, `share/extensions.txt` | Data both the shell and PHP read. A new PHP version is one row. |
| `share/systemd/`, `share/caddy/`, `share/compose/` | Unit and config templates. |
| `share/tunnels.tsv` | Share backends. The first row is the one in use. |
| `share/omarchy/covey/` | omarchy-shell bar widget and settings window. |
| `agents/skills/covey/` | Agent skill installed by `covey install`. |
| `packaging/aur/` | PKGBUILD for the AUR. Release tags only. |

## Verifying

There is no unit-test suite. The check is `covey doctor`, including the
failure paths, because a silent failure is the bug covey exists to remove.

```bash
covey doctor            # exit 0 when healthy
covey doctor --json     # the model the bar and agents read
covey status
covey down && covey doctor   # stopped is a state, exit 0, no fixes offered
```

Cheap ways to force a real failure:

```bash
mkdir ~/Covey/x && printf 'database = nope\n' > ~/Covey/x/.covey   # database_missing
printf 'php = 8.2\n' > ~/Covey/x/.covey                            # no_provider
docker compose -f share/compose/covey.yaml stop redis              # service_down
```

Remove `~/Covey/x` when you are done, and start redis again if you stopped it.

The bar widget has to be looked at. `docs/HACKING.md` has the capture
steps (`grim`, `omarchy-shell covey toggle`). A QML change that has not
been opened in the shell is not done.

`shellcheck bin/covey bin/covey-fpm-run` should stay clean.

## Pull requests

- Describe the behaviour a user can see, and why the current behaviour is wrong.
- Keep the diff to that behaviour. A drive-by refactor of `core.php` is a separate change.
- New checks need a stable `problem` code. A `fix.cmd` has to be a command an agent can run blindly; otherwise send a `hint` and no `fix`.
- Do not add a PHP provider you have not run. `share/providers.tsv` is verified rows only.

## Reporting a bug

Open a [bug report](https://github.com/gig3m/covey/issues/new?template=bug_report.yml)
and paste `covey doctor`. The `problem` field is more useful than a
paraphrase of the message. Say which distro you are on. covey is developed
on Arch; a report from somewhere else is still welcome, and it helps to
know that the paths in `share/providers.tsv` do not match that system.

## License

By contributing you agree that your work is licensed under the
[MIT License](LICENSE).
