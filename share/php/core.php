<?php
// covey core: provider registry, PHP version resolution, and the check model.
// Both `covey sync` and `covey doctor` go through here so they cannot disagree.
//
// usage: core.php resolve <site-dir>
//        core.php doctor [--json] [--resources]

const OK = true;

function env_or(string $k, string $d): string { $v = getenv($k); return $v === false || $v === '' ? $d : $v; }

$HOME    = env_or('HOME', '/root');
$COVEY   = env_or('COVEY_HOME',    "$HOME/.local/share/covey");
$SITES   = env_or('COVEY_SITES',   "$HOME/Covey");
$RUNTIME = env_or('XDG_RUNTIME_DIR', '/run/user/' . getmyuid());
$DEFAULT = env_or('COVEY_DEFAULT_PHP', '85');
$CONFIG  = env_or('COVEY_CONFIG',  "$HOME/.config/covey");

// ---- providers -------------------------------------------------------------
function providers(): array {
    global $COVEY;
    static $p = null;
    if ($p !== null) return $p;
    $p = [];
    foreach (file("$COVEY/share/providers.tsv", FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
        if ($line === '' || $line[0] === '#') continue;
        $f = explode("\t", $line);
        if (count($f) < 7) continue;
        $p[$f[0]] = ['tag'=>$f[0],'series'=>$f[1],'php'=>$f[2],'fpm'=>$f[3],
                     'pkgs'=>$f[4],'confdir'=>$f[5],'prefix'=>$f[6]];
    }
    return $p;
}
function provider(string $tag): ?array { return providers()[$tag] ?? null; }
function tag_installed(string $tag): bool {
    $p = provider($tag);
    return $p && is_executable($p['php']) && is_executable($p['fpm']);
}
function tag_version(string $tag): string {
    $p = provider($tag); if (!$p) return '';
    if (!is_executable($p['php'])) return $p['series'];
    $v = @shell_exec(escapeshellarg($p['php']) . ' -r "echo PHP_VERSION;" 2>/dev/null');
    return trim((string)$v) ?: $p['series'];
}
function tag_for_series(string $s): ?string {
    foreach (providers() as $t => $p) if ($p['series'] === $s) return $t;
    return null;
}
function covey_extensions(): array {
    global $COVEY;
    $f = "$COVEY/share/extensions.txt";
    return is_file($f) ? array_values(array_filter(array_map('trim', file($f)))) : [];
}

// ---- services ----------------------------------------------------------------
// What covey's compose stack offers a project, in one place: doctor's port
// checks, `covey status` and the bar's config pane all read this. The ports
// also appear in share/compose/covey.yaml, which is what actually binds them;
// image tags are read from there rather than repeated here.
//
// Credentials are the ones a stock Laravel .env already uses, which is why
// `env` can be shown verbatim: these are the lines that work unchanged.
const SERVICES = [
    'mysql' => ['label'=>'MySQL (MariaDB)', 'port'=>3306,
        'user'=>'root', 'password'=>'',
        'env'=>['DB_CONNECTION=mysql', 'DB_HOST=127.0.0.1', 'DB_PORT=3306',
                'DB_USERNAME=root', 'DB_PASSWORD='],
        'shell'=>'covey db shell'],
    'postgres' => ['label'=>'PostgreSQL', 'port'=>5432,
        'user'=>'root', 'password'=>'',
        'env'=>['DB_CONNECTION=pgsql', 'DB_HOST=127.0.0.1', 'DB_PORT=5432',
                'DB_USERNAME=root', 'DB_PASSWORD=']],
    'redis' => ['label'=>'Redis', 'port'=>6379,
        'env'=>['REDIS_HOST=127.0.0.1', 'REDIS_PORT=6379']],
    'mailpit' => ['label'=>'Mailpit', 'port'=>1025, 'ui_port'=>8025,
        'url'=>'https://mail.localhost',
        'env'=>['MAIL_MAILER=smtp', 'MAIL_HOST=127.0.0.1', 'MAIL_PORT=1025']],
];

// Names covey serves itself. A ~/Covey directory with one of these names would
// collide with covey's own Caddy block, so it is not served (see doctor).
const RESERVED_SITES = ['mail' => 'Mailpit is served at mail.localhost'];

// service => image, from the compose file. A deliberately small parse: the file
// is covey's own and keeps `image:` directly under each service.
function service_images(): array {
    global $COVEY;
    $f = "$COVEY/share/compose/covey.yaml";
    $out = []; $svc = null;
    foreach (is_file($f) ? file($f, FILE_IGNORE_NEW_LINES) : [] as $l) {
        if (preg_match('/^  ([a-z0-9_-]+):\s*$/', $l, $m)) { $svc = $m[1]; continue; }
        if ($svc && preg_match('/^    image:\s*(\S+)/', $l, $m)) $out[$svc] = $m[1];
    }
    return $out;
}

// ---- sharing -----------------------------------------------------------------
// `covey share <site>` puts a site on a public URL through a tunnel tool. The
// tool is data (share/tunnels.tsv), not code, so covey is not tied to any one
// vendor: the first row is the one used.
function tunnel(): ?array {
    global $COVEY;
    foreach (file("$COVEY/share/tunnels.tsv", FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [] as $l) {
        if ($l === '' || $l[0] === '#') continue;
        $f = explode("\t", $l);
        if (count($f) < 5) continue;
        return ['name'=>$f[0], 'bin'=>$f[1], 'pkg'=>$f[2], 'args'=>$f[3], 'url_regex'=>$f[4]];
    }
    return null;
}

// The loopback port a shared site's listener uses. Derived from the name, so
// the Caddy block and the tunnel unit agree without storing anything.
// 41000-41999; @PORT2@ (the tool's own port) is this + 1000.
function share_port(string $name): int { return 41000 + crc32($name) % 1000; }

// Sites being shared, from systemd: a share is a running unit, so - as with
// the stack - there is no marker file to drift from it. name => unit state.
function shares(): array {
    $out = (string)@shell_exec("systemctl --user list-units 'covey-share@*' --all --plain --no-legend 2>/dev/null");
    $res = [];
    foreach (explode("\n", $out) as $l) {
        $f = preg_split('/\s+/', trim($l));
        if (count($f) < 3 || !preg_match('/^covey-share@(.+)\.service$/', $f[0], $m)) continue;
        // f: unit load active sub
        if (in_array($f[2], ['active', 'activating', 'failed'], true)) $res[$m[1]] = $f[2];
    }
    return $res;
}

// The public URL, from the current run of the unit's journal. Each run of a
// quick tunnel gets a new URL, so only this invocation's output counts.
function share_url(string $name): ?string {
    $t = tunnel();
    if (!$t) return null;
    $u = escapeshellarg("covey-share@$name.service");
    $inv = trim((string)@shell_exec("systemctl --user show -p InvocationID --value $u 2>/dev/null"));
    if ($inv === '') return null;
    $log = (string)@shell_exec("journalctl --user -u $u _SYSTEMD_INVOCATION_ID=" . escapeshellarg($inv)
        . ' -o cat --no-pager 2>/dev/null');
    return preg_match_all('#' . str_replace('#', '\#', $t['url_regex']) . '#', $log, $m) ? end($m[0]) : null;
}

// ---- php.ini settings --------------------------------------------------------
// The settings a served site sees, applied to every FPM pool as php_value
// lines (so an app can still ini_set() over them, as with a real php.ini).
// These are the ones covey shows and sets by default; `covey php set` accepts
// any key PHP knows. Values are covey's, not PHP's stock defaults: 2M uploads
// and 128M of memory are what make a fresh local app fall over.
const PHP_INI_DEFAULTS = [
    'memory_limit'        => '512M',
    'upload_max_filesize' => '64M',
    'post_max_size'       => '64M',
    'max_execution_time'  => '60',
    'max_input_vars'      => '5000',
];

// The user's choices, from ~/.config/covey/php.ini. Like `disabled`, this is
// declared intent that nothing else on the machine records, and it lives with
// covey's config - never in a project, and never in /etc (that needs root).
function php_ini_custom(): array {
    global $CONFIG;
    $f = "$CONFIG/php.ini";
    $out = [];
    if (!is_file($f)) return $out;
    foreach (file($f, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $l) {
        if (preg_match('/^\s*[;#]/', $l)) continue;
        if (preg_match('/^\s*([a-z][a-z0-9_.]*)\s*=\s*(.*?)\s*$/', $l, $m)) $out[$m[1]] = $m[2];
    }
    return $out;
}
// What may appear in a setting. Values are written verbatim into the FPM pool
// config, so anything that could end the line or start a new directive - a
// CR, a quote, ;, =, [ - would let a value rewrite the pool (one test turned
// `512M\rlisten = 0.0.0.0:19000` into a network listener). Allow-list instead.
function ini_valid(string $k, string $v): bool {
    return preg_match('/^[a-z][a-z0-9_.]*$/', $k) === 1
        && preg_match('#^[A-Za-z0-9 ._/:+~&|^!-]{1,200}$#', $v) === 1;
}
// Lines in the user's file that fail the check, for doctor to report.
function php_ini_invalid(): array {
    global $CONFIG;
    $bad = [];
    foreach (is_file("$CONFIG/php.ini") ? file("$CONFIG/php.ini", FILE_IGNORE_NEW_LINES) : [] as $l) {
        if (trim($l) === '' || preg_match('/^\s*[;#]/', $l)) continue;
        if (!preg_match('/^\s*([a-z][a-z0-9_.]*)\s*=\s*(.*?)\s*$/', $l, $m) || !ini_valid($m[1], $m[2]))
            $bad[] = $l;
    }
    return $bad;
}
// Effective settings: defaults, overridden by the user's file (valid lines only).
function php_ini(): array {
    return array_merge(PHP_INI_DEFAULTS,
        array_filter(php_ini_custom(), fn($v, $k) => ini_valid($k, $v), ARRAY_FILTER_USE_BOTH));
}

// "64M" -> bytes, for comparing sizes. PHP's own shorthand: K, M, G.
function ini_bytes(string $v): ?int {
    if (!preg_match('/^\s*(\d+)\s*([KMG]?)\s*$/i', $v, $m)) return null;
    return (int)$m[1] * ['' => 1, 'K' => 1024, 'M' => 1048576, 'G' => 1073741824][strtoupper($m[2])];
}

// ---- constraint matching ---------------------------------------------------
function vnorm(string $v): string {
    $p = array_map('intval', array_pad(explode('.', trim($v)), 3, 0));
    return "{$p[0]}.{$p[1]}.{$p[2]}";
}
function term_ok(string $t, string $v): bool {
    $t = trim($t);
    if ($t === '' || $t === '*') return true;
    if (preg_match('/^\^\s*(.+)$/', $t, $m)) {
        $b = explode('.', trim($m[1]));
        $hi = ((int)$b[0] > 0) ? ((int)$b[0]+1).'.0.0' : '0.'.((int)($b[1] ?? 0)+1).'.0';
        return version_compare($v, vnorm($m[1]), '>=') && version_compare($v, $hi, '<');
    }
    if (preg_match('/^~\s*(.+)$/', $t, $m)) {
        $b = explode('.', trim($m[1]));
        $hi = (count($b) >= 3) ? $b[0].'.'.((int)$b[1]+1).'.0' : ((int)$b[0]+1).'.0.0';
        return version_compare($v, vnorm($m[1]), '>=') && version_compare($v, $hi, '<');
    }
    if (preg_match('/^(\d+)\.(\d+)\.\*$/', $t, $m)) {
        return version_compare($v, "{$m[1]}.{$m[2]}.0", '>=')
            && version_compare($v, $m[1].'.'.((int)$m[2]+1).'.0', '<');
    }
    if (preg_match('/^(>=|<=|!=|>|<|=)\s*(.+)$/', $t, $m)) {
        return version_compare($v, vnorm($m[2]), $m[1] === '=' ? '==' : $m[1]);
    }
    $b = explode('.', $t);
    if (count($b) === 2) {
        return version_compare($v, vnorm($t), '>=')
            && version_compare($v, $b[0].'.'.((int)$b[1]+1).'.0', '<');
    }
    return version_compare($v, vnorm($t), '==');
}
function satisfies(string $c, string $v): bool {
    foreach (explode('||', $c) as $alt) {
        $ok = true;
        foreach (preg_split('/[,\s]+/', trim($alt), -1, PREG_SPLIT_NO_EMPTY) as $t)
            if (!term_ok($t, $v)) { $ok = false; break; }
        if ($ok) return true;
    }
    return false;
}

// ---- site config -----------------------------------------------------------
function covey_file(string $dir): array {
    $f = "$dir/.covey";
    if (!is_file($f)) return [];
    $out = [];
    foreach (file($f, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
        if (preg_match('/^\s*#/', $line)) continue;
        if (preg_match('/^\s*([A-Za-z_]+)\s*=\s*"?([^"#]*?)"?\s*$/', $line, $m))
            $out[strtolower($m[1])] = trim($m[2]);
    }
    return $out;
}
function composer_constraint(string $dir): ?string {
    $f = "$dir/composer.json";
    if (!is_file($f)) return null;
    $j = json_decode((string)@file_get_contents($f), true);
    $c = is_array($j) ? ($j['require']['php'] ?? '') : '';
    return $c !== '' ? $c : null;
}

// Resolution: .covey -> composer.json -> default. Default wins if it satisfies.
function resolve_site(string $dir): array {
    global $DEFAULT;
    $cf = covey_file($dir);
    if (!empty($cf['php'])) {
        $t = tag_for_series($cf['php']);
        if ($t && tag_installed($t)) return ['tag'=>$t, 'source'=>'.covey', 'required'=>$cf['php']];
        return ['tag'=>$DEFAULT, 'source'=>'.covey', 'required'=>$cf['php'],
                'problem'=>'provider_not_installed', 'wanted_series'=>$cf['php']];
    }
    $c = composer_constraint($dir);
    if ($c !== null) {
        if (satisfies($c, tag_version($DEFAULT))) return ['tag'=>$DEFAULT,'source'=>'composer.json','required'=>$c];
        $best = null;
        foreach (providers() as $t => $p) {
            if (!tag_installed($t)) continue;
            $v = tag_version($t);
            if (satisfies($c, $v) && ($best === null || version_compare($v, $best[1], '>'))) $best = [$t, $v];
        }
        if ($best) return ['tag'=>$best[0], 'source'=>'composer.json', 'required'=>$c];
        return ['tag'=>$DEFAULT, 'source'=>'composer.json', 'required'=>$c,
                'problem'=>'constraint_unsatisfiable'];
    }
    return ['tag'=>$DEFAULT, 'source'=>'default', 'required'=>null];
}

function sites(): array {
    global $SITES;
    $out = [];
    foreach (glob("$SITES/*", GLOB_ONLYDIR) ?: [] as $dir) {
        $n = basename($dir);
        // Dotted names allowed: example.com -> example.com.localhost
        if (!preg_match('/^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$/', $n)) continue;
        if (isset(RESERVED_SITES[strtolower($n)])) continue;
        $out[$n] = $dir;
    }
    return $out;
}

// ---- enablement ------------------------------------------------------------
// Per-site up/down. Unlike the stack's up/down -- an *observation*, derived
// from systemd -- a site's is *declared intent*, and there is nothing to derive
// it from: a site is a generated Caddy block, not a unit. It cannot live in the
// generated Caddyfile either, since `covey sync` overwrites that from scratch,
// nor in the project's own `.covey`, because covey never writes inside a
// project. So it is stored here, in one covey-owned file naming what is off.
// This is input, not a cached copy of a fact something else already knows,
// which is what keeps it from being the kind of marker file that drifts.
function disabled_sites(): array {
    global $CONFIG;
    static $cache = null;
    if ($cache !== null) return $cache;
    $cache = [];
    $f = "$CONFIG/disabled";
    if (is_file($f)) {
        foreach (file($f, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $l) {
            $l = trim($l);
            if ($l === '' || $l[0] === '#') continue;
            $cache[$l] = true;
        }
    }
    return $cache;
}
function site_enabled(string $name): bool { return !isset(disabled_sites()[$name]); }

// Solo mode: `covey site solo <name>` turns every other site off and keeps the
// list that was off before, so `covey site restore` can put it back exactly.
// The file's first line is the solo site; the rest is that saved list. Like
// `disabled`, it is declared intent - nothing else on the machine knows it.
function solo_site(): ?string {
    global $CONFIG;
    $f = "$CONFIG/solo";
    if (!is_file($f)) return null;
    $l = trim((string)strtok((string)file_get_contents($f), "\n"));
    return $l === '' ? null : $l;
}

// ---- checks ----------------------------------------------------------------
function unit_active(string $u): bool {
    exec('systemctl --user is-active --quiet ' . escapeshellarg($u), $o, $rc);
    return $rc === 0;
}

// The target *is* the stack: `covey down` stops it, `covey up` starts it. An
// inactive target therefore means "stopped on purpose", not "broken", and
// doctor must not report eight red failures (each with a fix telling an agent
// to start it again) for a stack the user deliberately took down. Deriving
// this from systemd rather than a marker file keeps it from drifting.
function stack_live(): bool { return unit_active('covey.target'); }

// Problems that mean the platform is not running, as opposed to not correct.
// These are what separate `degraded` from a merely failing check.
const RUNTIME_PROBLEMS = ['caddy_inactive', 'pool_inactive', 'service_down', 'docker_unavailable'];

// The PHP versions this machine's sites actually ask for.
function needed_tags(): array {
    global $DEFAULT;
    $n = [];
    // Only enabled sites keep a pool alive; that is what makes `covey site down`
    // able to free one, rather than merely stop serving.
    foreach (sites() as $name => $d) {
        if (!site_enabled($name)) continue;
        $n[resolve_site($d)['tag']] = true;
    }
    if (!$n) $n[$DEFAULT] = true;
    return array_keys($n);
}
function port_open(string $host, int $port, float $t = 1.5): bool {
    $s = @fsockopen($host, $port, $e, $es, $t);
    if ($s) { fclose($s); return true; }
    return false;
}
function chk(string $name, bool $ok, array $extra = []): array {
    return array_merge(['check'=>$name, 'ok'=>$ok], $extra);
}
function fix(string $cmd, bool $root = false): array { return ['cmd'=>$cmd, 'needs_root'=>$root]; }

// $live says whether the stack is meant to be running. When it is not, only
// the static checks are run - what is installed and configured is still worth
// knowing while covey is down; what is listening on a port is not.
function platform_checks(bool $live): array {
    $c = [];
    if ($live) {
        $c[] = unit_active('covey-caddy.service')
            ? chk('caddy', OK)
            : chk('caddy', false, ['problem'=>'caddy_inactive','detail'=>'web server is not running',
                                   'fix'=>fix('covey up')]);
    }

    foreach (needed_tags() as $tag) {
        $p = provider($tag);
        $series = $p['series'] ?? $tag;
        if (!tag_installed($tag)) {
            $c[] = chk("php-$series", false, ['problem'=>'provider_not_installed',
                'detail'=>"PHP $series is not installed",
                'fix'=>fix("covey php install $tag", true)]);
            continue;
        }
        if (!$live) {
            $c[] = chk("php-$series", OK, ['detail'=>tag_version($tag)]);
        } else {
            $c[] = unit_active("covey-fpm@$tag.service")
                ? chk("php-$series", OK, ['detail'=>tag_version($tag)])
                : chk("php-$series", false, ['problem'=>'pool_inactive',
                    'detail'=>"FPM pool for $series is not running", 'fix'=>fix('covey up')]);
        }

        $missing = [];
        $loaded = strtolower((string)@shell_exec(escapeshellarg($p['php']) . ' -m 2>/dev/null'));
        $loaded = preg_split('/\s+/', $loaded, -1, PREG_SPLIT_NO_EMPTY) ?: [];
        foreach (covey_extensions() as $e) if (!in_array(strtolower($e), $loaded, true)) $missing[] = $e;
        $c[] = $missing
            ? chk("extensions-$series", false, ['problem'=>'extensions_missing',
                'detail'=>implode(' ', $missing), 'fix'=>fix("covey php configure $tag", true)])
            : chk("extensions-$series", OK);
    }

    // A project directory named like one of covey's own hosts is not served;
    // say so, rather than letting it silently not appear. Renaming it is the
    // user's call - covey does not move project directories - so a hint only.
    global $SITES;
    foreach (RESERVED_SITES as $n => $why) {
        if (is_dir("$SITES/$n")) $c[] = chk("site-$n", false, ['problem'=>'reserved_name',
            'detail'=>"$SITES/$n is not served: $why",
            'hint'=>"rename the directory; $n.localhost belongs to covey"]);
    }

    // An upload larger than post_max_size is dropped before PHP sees it: the
    // request arrives with an empty body and no error. Easy to cause by raising
    // one setting and not the other, and miserable to debug from the app side.
    $ini = php_ini();
    $up = ini_bytes($ini['upload_max_filesize'] ?? ''); $post = ini_bytes($ini['post_max_size'] ?? '');
    if ($up !== null && $post !== null && $post > 0 && $up > $post) {
        $c[] = chk('php-ini', false, ['problem'=>'ini_upload_exceeds_post',
            'detail'=>"upload_max_filesize ({$ini['upload_max_filesize']}) is larger than post_max_size ({$ini['post_max_size']})",
            'fix'=>fix("covey php set post_max_size {$ini['upload_max_filesize']}")]);
    }

    // Lines covey refused to apply (a hand edit). Unsetting is safe whatever the
    // value was, but the key may itself be the malformed part - so a hint.
    foreach (php_ini_invalid() as $l) {
        $c[] = chk('php-ini', false, ['problem'=>'php_ini_invalid',
            'detail'=>'ignored line in ' . $GLOBALS['CONFIG'] . '/php.ini: ' . preg_replace('/[[:cntrl:]]/', '?', $l),
            'hint'=>'edit or delete that line; values may use letters, digits, spaces and . / : _ - + ~ & | ^ !']);
    }

    // Browsers read NSS, not the system store; being trusted by curl says nothing.
    $nss = getenv('HOME') . '/.pki/nssdb';
    if (is_dir($nss)) {
        $out = (string)@shell_exec('certutil -d ' . escapeshellarg("sql:$nss") . ' -L 2>/dev/null');
        $c[] = (stripos($out, 'Caddy Local Authority') !== false)
            ? chk('browser-trust', OK, ['detail'=>'local CA in NSS store'])
            : chk('browser-trust', false, ['problem'=>'ca_untrusted_by_browsers',
                'detail'=>'local CA is not in the browser (NSS) store',
                'fix'=>fix('covey trust', true)]);
    } else {
        $c[] = chk('browser-trust', false, ['problem'=>'ca_untrusted_by_browsers',
            'detail'=>'no NSS store; browsers will reject the certificate',
            'fix'=>fix('covey trust', true)]);
    }

    if (!$live) return $c;

    exec('docker info >/dev/null 2>&1', $o, $rc);
    if ($rc !== 0) {
        $c[] = chk('docker', false, ['problem'=>'docker_unavailable',
            'detail'=>'docker is not responding', 'fix'=>fix('sudo systemctl start docker', true)]);
        return $c;
    }
    $c[] = chk('docker', OK);
    foreach (SERVICES as $svc => $def) {
        $port = $def['port'];
        $c[] = port_open('127.0.0.1', $port)
            ? chk($svc, OK, ['detail'=>"127.0.0.1:$port"])
            : chk($svc, false, ['problem'=>'service_down',
                'detail'=>"nothing listening on 127.0.0.1:$port",
                'fix'=>fix('covey services up')]);
    }
    return $c;
}

function http_check(string $name): array {
    $url = "https://$name.localhost/";
    $ch = curl_init($url);
    curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER=>true, CURLOPT_TIMEOUT=>8,
        CURLOPT_SSL_VERIFYPEER=>true, CURLOPT_SSL_VERIFYHOST=>2, CURLOPT_NOBODY=>true]);
    curl_exec($ch);
    $errno = curl_errno($ch);
    $code  = (int)curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
    curl_close($ch);
    if ($errno === CURLE_SSL_CACERT || $errno === 60) {
        return chk('https', false, ['problem'=>'tls_untrusted',
            'detail'=>'certificate not trusted by the system store',
            'fix'=>fix('sudo caddy trust', true)]);
    }
    if ($errno !== 0) {
        return chk('https', false, ['problem'=>'http_failed',
            'detail'=>curl_strerror($errno), 'fix'=>fix('covey logs caddy')]);
    }
    if ($code >= 500) {
        return chk('https', false, ['problem'=>'http_5xx',
            'detail'=>"HTTP $code", 'fix'=>fix('covey logs php')]);
    }
    return chk('https', OK, ['detail'=>"HTTP $code"]);
}

function db_exists(string $name): ?bool {
    if (!class_exists('mysqli')) return null;
    $c = @new mysqli('127.0.0.1', 'root', '', '', 3306);
    if ($c->connect_errno) return null;
    $r = $c->query("SHOW DATABASES LIKE '" . $c->real_escape_string($name) . "'");
    $n = $r ? $r->num_rows : 0;
    $c->close();
    return $n > 0;
}

// Ask composer what the project's own dependencies need from the platform.
// This catches extensions covey does not ship - the class of problem covey's
// own fixed extension list cannot see.
function platform_reqs_check(string $dir, string $tag): ?array {
    if (!is_file("$dir/composer.lock") || !is_file('/usr/bin/composer')) return null;
    $p = provider($tag);
    if (!$p || !is_executable($p['php'])) return null;
    $cmd = escapeshellarg($p['php']) . ' /usr/bin/composer check-platform-reqs --no-interaction '
         . '-d ' . escapeshellarg($dir) . ' 2>/dev/null';
    $out = (string)@shell_exec($cmd);
    if (trim($out) === '') return null;
    $missing = [];
    foreach (explode("\n", $out) as $line) {
        if (stripos($line, 'missing') === false) continue;
        if (preg_match('/^\s*ext-([A-Za-z0-9_]+)/', $line, $m)) $missing[] = $m[1];
    }
    $missing = array_values(array_unique($missing));
    if (!$missing) return chk('platform-reqs', OK, ['detail'=>'composer requirements satisfied']);

    // If covey already manages every missing extension, configure fixes it.
    $known = array_map('strtolower', covey_extensions());
    $unmanaged = array_values(array_diff(array_map('strtolower', $missing), $known));
    $extra = ['problem'=>'platform_reqs_missing', 'detail'=>implode(' ', array_map(fn($e)=>"ext-$e", $missing))];
    if (!$unmanaged) $extra['fix'] = fix("covey php configure $tag", true);
    else $extra['hint'] = 'not in covey\'s extension set: ' . implode(' ', $unmanaged)
                        . ' - add to share/extensions.txt (and a package to COVEY_EXT_PKGS if needed)';
    return chk('platform-reqs', false, $extra);
}

function site_report(string $name, string $dir, bool $live): array {
    $r = resolve_site($dir);
    $p = provider($r['tag']);
    $checks = [];
    $enabled = site_enabled($name);
    $ident = ['name'=>$name, 'url'=>"https://$name.localhost", 'path'=>$dir,
              'enabled'=>$enabled,
              'php'=>['tag'=>$r['tag'], 'series'=>$p['series'] ?? null,
                      'resolved'=>tag_version($r['tag']), 'required'=>$r['required'],
                      'source'=>$r['source']]];

    // A disabled site is a state, not a failure -- the same rule the stack
    // already follows. It emits no check that can fail, so taking a site down
    // is a way to make a green doctor mean something again. Its real checks
    // come back untouched on `covey site up`.
    if (!$enabled) {
        $ident['checks'] = [chk('site', OK, ['detail'=>'disabled (covey site up ' . $name . ')'])];
        return $ident;
    }

    if (($r['problem'] ?? '') === 'provider_not_installed') {
        $t = tag_for_series($r['wanted_series'] ?? '');
        // Only emit `fix` when there is a real command to run; otherwise a hint,
        // so an agent never tries to execute prose.
        $extra = ['problem'=>'provider_not_installed',
                  'detail'=>".covey pins php {$r['wanted_series']}, which is not installed"];
        if ($t) { $extra['fix'] = fix("covey php install $t", true); }
        else    { $extra['problem'] = 'no_provider';
                  $extra['hint'] = "covey has no provider for PHP {$r['wanted_series']}; "
                                 . "add a row to share/providers.tsv"; }
        $checks[] = chk('php', false, $extra);
    } elseif (($r['problem'] ?? '') === 'constraint_unsatisfiable') {
        $checks[] = chk('php', false, ['problem'=>'constraint_unsatisfiable',
            'detail'=>"no installed PHP satisfies '{$r['required']}'",
            'fix'=>fix('covey php list')]);
    } else {
        $checks[] = chk('php', OK, ['detail'=>tag_version($r['tag']) . " (from {$r['source']})"]);
    }

    // Sharing. A running share is a state, reported on the site; a share
    // whose unit failed is a failure, with a retry as its fix.
    $sh = shares()[$name] ?? null;
    if ($sh !== null) {
        $url = $sh === 'failed' ? null : share_url($name);
        $ident['share'] = ['state'=>$sh, 'url'=>$url, 'port'=>share_port($name),
                           'tunnel'=>tunnel()['name'] ?? null];
        $checks[] = $sh === 'failed'
            // The fix clears the failed share. Re-sharing republishes the
            // site, which only a person should decide - so it is not a fix.
            ? chk('share', false, ['problem'=>'share_failed',
                'detail'=>"the tunnel for $name stopped (journalctl --user -u covey-share@$name); "
                        . "covey share $name to share it again",
                'fix'=>fix("covey unshare $name")])
            : chk('share', OK, ['detail'=>$url ?? 'starting']);
    } else {
        $ident['share'] = null;
    }

    $pr = platform_reqs_check($dir, $r['tag']);
    if ($pr !== null) $checks[] = $pr;

    if ($live) $checks[] = http_check($name);

    $cf = covey_file($dir);
    // The name comes from the project's .covey, so it is untrusted text: it ends
    // up in a fix.cmd that agents run blindly and the settings window runs in a
    // shell. Only names `covey db create` would accept get a fix at all.
    if ($live && !empty($cf['database']) && !preg_match('/^[A-Za-z0-9_]+$/', $cf['database'])) {
        $checks[] = chk('database', false, ['problem'=>'database_name_invalid',
            'detail'=>'.covey database name is not a plain identifier',
            'hint'=>'use letters, digits and underscores in the database = line of .covey']);
    } elseif ($live && !empty($cf['database'])) {
        $e = db_exists($cf['database']);
        $checks[] = $e === true
            ? chk('database', OK, ['detail'=>$cf['database']])
            : ($e === null
                ? chk('database', false, ['problem'=>'service_down',
                    'detail'=>'cannot reach mysql', 'fix'=>fix('covey services up')])
                : chk('database', false, ['problem'=>'database_missing',
                    'detail'=>"database '{$cf['database']}' does not exist",
                    'fix'=>fix("covey db create {$cf['database']}")]));
    }

    $ident['checks'] = $checks;
    return $ident;
}

// ---- resources -------------------------------------------------------------
// What the stack costs to leave running. systemd's MemoryCurrent is a free
// property read; `docker stats` needs a ~2s sample per call, so containers are
// only measured when asked for (`covey status`, `doctor --resources`) and never
// on the path the bar widget polls.
function unit_memory(array $units): array {
    if (!$units) return [];
    $out = (string)@shell_exec('systemctl --user show -p Id -p MemoryCurrent '
        . implode(' ', array_map('escapeshellarg', $units)) . ' 2>/dev/null');
    $res = []; $id = null;
    foreach (explode("\n", $out) as $line) {
        if (str_starts_with($line, 'Id=')) { $id = substr($line, 3); continue; }
        if (str_starts_with($line, 'MemoryCurrent=') && $id !== null) {
            $v = substr($line, 14);
            $res[] = ['name'=>$id, 'bytes'=>ctype_digit($v) ? (int)$v : null];
            $id = null;
        }
    }
    return $res;
}

// "170.5MiB" -> bytes. docker stats reports no raw figure.
function human_bytes(string $s): ?int {
    if (!preg_match('/^([0-9.]+)\s*([KMGT]?i?B)$/i', trim($s), $m)) return null;
    $mult = ['B'=>1, 'KIB'=>1024, 'MIB'=>1048576, 'GIB'=>1073741824, 'TIB'=>1099511627776,
             'KB'=>1000, 'MB'=>1000000, 'GB'=>1000000000, 'TB'=>1000000000000];
    $u = strtoupper($m[2]);
    return isset($mult[$u]) ? (int)round((float)$m[1] * $mult[$u]) : null;
}

function container_memory(): array {
    $out = (string)@shell_exec('docker stats --no-stream --format '
        . escapeshellarg('{{.Name}}\t{{.MemUsage}}') . ' 2>/dev/null');
    $res = [];
    foreach (explode("\n", $out) as $line) {
        $f = explode("\t", $line);
        if (count($f) < 2 || !str_starts_with($f[0], 'covey-')) continue;
        $res[] = ['name'=>$f[0], 'bytes'=>human_bytes(explode('/', $f[1])[0])];
    }
    return $res;
}

function resources(bool $live, bool $containers): array {
    $units = [];
    if ($live) {
        // Every provider, not just the needed ones: a pool can still be running
        // for a site that has since gone away, and it is still using memory.
        $u = ['covey-caddy.service'];
        foreach (array_keys(providers()) as $t) $u[] = "covey-fpm@$t.service";
        $units = array_values(array_filter(unit_memory($u), fn($r) => $r['bytes'] !== null));
    }
    $cs = ($live && $containers) ? container_memory() : [];
    $total = 0;
    foreach (array_merge($units, $cs) as $r) $total += (int)($r['bytes'] ?? 0);
    return ['units'=>$units, 'containers'=>$containers ? $cs : null, 'bytes'=>$total];
}

function doctor(bool $containers = false): array {
    $live = stack_live();
    $platform = platform_checks($live);
    $sites = [];
    foreach (sites() as $n => $d) $sites[] = site_report($n, $d, $live);
    $ok = true; $degraded = false;
    foreach ($platform as $c) if (!$c['ok']) {
        $ok = false;
        if (in_array($c['problem'] ?? '', RUNTIME_PROBLEMS, true)) $degraded = true;
    }
    foreach ($sites as $s) foreach ($s['checks'] as $c) if (!$c['ok']) $ok = false;
    return ['ok'=>$ok,
            'state'=>!$live ? 'down' : ($degraded ? 'degraded' : 'up'),
            'solo'=>solo_site(),
            'resources'=>resources($live, $containers),
            'platform'=>$platform, 'sites'=>$sites];
}

// ---- status ----------------------------------------------------------------
// A cheap runtime-only view: what is running and what it costs. Deliberately
// not doctor - no HTTP, no composer, no correctness. `covey status` answers
// "is it up and what is it costing me", `covey doctor` answers "is it right".
function status(bool $containers = true): array {
    $live = stack_live();
    $needed = array_flip(needed_tags());
    $names = ['covey-caddy.service'];
    foreach (array_keys(providers()) as $t) {
        $u = "covey-fpm@$t.service";
        if (isset($needed[$t]) || unit_active($u)) $names[] = $u;
    }
    $names[] = 'covey-sync.path';
    $names[] = 'covey-services.service';

    $mem = [];
    foreach (unit_memory($names) as $r) $mem[$r['name']] = $r['bytes'];
    $units = [];
    foreach ($names as $u)
        $units[] = ['name'=>$u, 'active'=>unit_active($u), 'bytes'=>$mem[$u] ?? null];

    $cs = ($live && $containers) ? container_memory() : [];
    $total = 0;
    foreach ($units as $r) $total += (int)($r['bytes'] ?? 0);
    foreach ($cs as $r) $total += (int)($r['bytes'] ?? 0);

    $degraded = false;
    if ($live) foreach ($units as $r)
        if (!$r['active'] && $r['name'] !== 'covey-sync.path') $degraded = true;

    return ['state'=>!$live ? 'down' : ($degraded ? 'degraded' : 'up'),
            'units'=>$units, 'containers'=>$containers ? $cs : null, 'bytes'=>$total,
            'services'=>services_inventory($live, $cs),
            'php'=>php_inventory($live),
            'php_ini'=>php_ini_inventory(),
            'shares'=>shares_inventory(),
            'settings'=>settings_inventory()];
}

// ---- inventory ---------------------------------------------------------------
// What covey provides and how to reach it - the information Herd puts in its
// settings window. Part of `status` rather than doctor: none of it is a check,
// and all of it is cheap (no HTTP, no composer). Doctor says whether it is
// right; this says what it is.

// $cs: container memory already measured by status(), reused rather than
// paying for a second `docker stats` sample.
function services_inventory(bool $live, array $cs): array {
    $images = service_images();
    $mem = [];
    foreach ($cs as $c) if (preg_match('/^covey-(.+)-\d+$/', $c['name'], $m)) $mem[$m[1]] = $c['bytes'];
    $out = [];
    foreach (SERVICES as $name => $d) {
        $out[] = array_merge(['name'=>$name, 'label'=>$d['label'],
            'image'=>$images[$name] ?? null,
            'up'=>$live && port_open('127.0.0.1', $d['port']),
            'host'=>'127.0.0.1', 'port'=>$d['port'],
            'bytes'=>$mem[$name] ?? null,
            'env'=>$d['env']],
            array_intersect_key($d, array_flip(['user', 'password', 'ui_port', 'url', 'shell'])));
    }
    return $out;
}

function php_inventory(bool $live): array {
    $using = [];
    foreach (sites() as $n => $d) {
        if (!site_enabled($n)) continue;
        $using[resolve_site($d)['tag']][] = $n;
    }
    $want = covey_extensions();
    $out = [];
    foreach (providers() as $tag => $p) {
        $installed = tag_installed($tag);
        $ext = null;
        if ($installed) {
            $loaded = strtolower((string)@shell_exec(escapeshellarg($p['php']) . ' -m 2>/dev/null'));
            $loaded = array_flip(preg_split('/\s+/', $loaded, -1, PREG_SPLIT_NO_EMPTY) ?: []);
            $ext = [];
            foreach ($want as $e) $ext[$e] = isset($loaded[strtolower($e)]);
        }
        // (string): PHP turns the numeric key "85" into int 85, and the
        // site model already reports tags as strings.
        $out[] = ['tag'=>(string)$tag, 'series'=>$p['series'], 'installed'=>$installed,
                  'version'=>$installed ? tag_version($tag) : null,
                  'pool'=>$live && unit_active("covey-fpm@$tag.service"),
                  'sites'=>$using[$tag] ?? [],
                  'extensions'=>$ext,
                  'install'=>$installed ? null : "covey php install $tag"];
    }
    return $out;
}

// One snapshot of shares(): two calls could disagree while a share starts.
function shares_inventory(): array {
    $out = [];
    foreach (shares() as $n => $st)
        $out[] = ['site'=>$n, 'state'=>$st, 'url'=>$st === 'failed' ? null : share_url($n),
                  'port'=>share_port($n)];
    return $out;
}

// Every effective setting, marking which the user changed. Keys covey sets by
// default come first, in their usual order.
function php_ini_inventory(): array {
    $custom = php_ini_custom();
    $out = [];
    foreach (php_ini() as $k => $v)
        $out[] = ['key'=>$k, 'value'=>$v, 'default'=>PHP_INI_DEFAULTS[$k] ?? null,
                  'custom'=>array_key_exists($k, $custom)];
    return $out;
}

function settings_inventory(): array {
    global $SITES, $CONFIG, $DEFAULT;
    $en = trim((string)@shell_exec('systemctl --user is-enabled covey.target 2>/dev/null'));
    $ups = @file_get_contents('/proc/sys/net/ipv4/ip_unprivileged_port_start');
    return ['sites_root'=>$SITES, 'config_dir'=>$CONFIG,
            'default_php'=>provider($DEFAULT)['series'] ?? $DEFAULT,
            'autostart'=>$en === 'enabled',
            // User services can only bind :80/:443 when this is <= 80.
            'unprivileged_port_start'=>$ups === false ? null : (int)trim($ups)];
}

function render_status(array $d): int {
    $tty = function_exists('posix_isatty') && @posix_isatty(STDOUT) && getenv('NO_COLOR') === false;
    $note = ['up'=>'running', 'degraded'=>'partly running', 'down'=>'stopped'][$d['state']] ?? $d['state'];
    if ($d['bytes'] > 0) $note .= '  (' . mib($d['bytes']) . ')';
    if ($tty) $note = ($d['state'] === 'down' ? "\033[2m" : ($d['state'] === 'up' ? "\033[32m" : "\033[31m"))
                    . $note . "\033[0m";
    printf("STACK    %s\n\n", $note);

    printf("%-26s %-10s %s\n", 'UNIT', 'STATE', 'MEMORY');
    foreach ($d['units'] as $u)
        printf("%-26s %-10s %8s\n", $u['name'], $u['active'] ? 'active' : 'inactive',
               $u['bytes'] === null ? '-' : mib($u['bytes']));

    if ($d['containers']) {
        printf("\n%-26s %s\n", 'CONTAINER', 'MEMORY');
        foreach ($d['containers'] as $c)
            printf("%-26s %8s\n", $c['name'], $c['bytes'] === null ? '-' : mib($c['bytes']));
    }

    printf("\n%-10s %-8s %-16s %s\n", 'SERVICE', 'STATE', 'ADDRESS', 'OPEN');
    foreach ($d['services'] as $s)
        printf("%-10s %-8s %-16s %s\n", $s['name'], $s['up'] ? 'up' : 'down',
               "{$s['host']}:{$s['port']}", $s['url'] ?? ($s['shell'] ?? ''));

    printf("\n%-22s %s\n", 'PHP.INI', 'VALUE');
    foreach ($d['php_ini'] as $i)
        printf("%-22s %s%s\n", $i['key'], $i['value'], $i['custom'] ? '  (set)' : '');

    printf("\n%-10s %-8s %-8s %s\n", 'PHP', 'VERSION', 'POOL', 'SITES');
    foreach ($d['php'] as $p)
        printf("%-10s %-8s %-8s %s\n", $p['series'], $p['version'] ?? '-',
               !$p['installed'] ? 'n/a' : ($p['pool'] ? 'running' : 'stopped'),
               $p['installed'] ? (count($p['sites']) ?: '-') : $p['install']);
    if ($d['state'] === 'down') echo "\ncovey is stopped - run `covey up` to start it\n";
    return $d['state'] === 'up' ? 0 : 1;
}

// ---- renderers -------------------------------------------------------------
function render_human(array $d): int {
    // Colour only for a terminal; padding is applied before colouring so the
    // escape sequences never count toward column width.
    $tty = function_exists('posix_isatty') && @posix_isatty(STDOUT) && getenv('NO_COLOR') === false;
    $mark = function (bool $ok) use ($tty) {
        $t = $ok ? 'ok  ' : 'FAIL';
        if (!$tty) return $t;
        return ($ok ? "\033[32m" : "\033[31m") . $t . "\033[0m";
    };
    $line = function (array $c) use ($mark) {
        printf("  %s %-16s %s\n", $mark($c['ok']), $c['check'], $c['detail'] ?? '');
        if (!$c['ok'] && isset($c['fix'])) {
            printf("       fix: %s%s\n", $c['fix']['cmd'], $c['fix']['needs_root'] ? '  (needs root)' : '');
        } elseif (!$c['ok'] && isset($c['hint'])) {
            printf("       %s\n", $c['hint']);
        }
    };
    $state = $d['state'] ?? 'up';
    $mem = (int)($d['resources']['bytes'] ?? 0);
    $note = ['up'=>'running', 'degraded'=>'partly running', 'down'=>'stopped'][$state] ?? $state;
    if ($state === 'up' && $mem > 0) $note .= sprintf('  (%s)', mib($mem));
    printf("STACK    %s\n", $tty ? ($state === 'down' ? "\033[2m$note\033[0m"
                                       : ($state === 'up' ? "\033[32m$note\033[0m" : "\033[31m$note\033[0m"))
                                     : $note);
    if (!empty($d['solo'])) printf("SOLO     %s  (covey site restore to end)\n", $d['solo']);
    echo "\nPLATFORM\n";
    foreach ($d['platform'] as $c) $line($c);
    foreach ($d['sites'] as $s) {
        // Dim a deliberately-disabled site rather than colouring it like a
        // failure; it is off on purpose.
        $hdr = sprintf("%s  %s", $s['name'], $s['url']);
        if (($s['enabled'] ?? true) === false) {
            $hdr = sprintf("%s  (disabled)", $s['name']);
            if ($tty) $hdr = "\033[2m$hdr\033[0m";
        }
        printf("\n%s\n", $hdr);
        foreach ($s['checks'] as $c) $line($c);
    }
    if (!$d['sites']) echo "\n(no sites)\n";
    // A stopped stack is not a broken one: say so, and do not claim the checks
    // that were skipped passed.
    if ($state === 'down') echo "\ncovey is stopped - run `covey up` to start it\n";
    else echo "\n" . ($d['ok'] ? "all checks passed\n" : "some checks failed\n");
    return $d['ok'] ? 0 : 1;
}

function mib(int $b): string { return sprintf('%.0f MiB', $b / 1048576); }

// ---- entry -----------------------------------------------------------------
$cmd = $argv[1] ?? 'doctor';
if ($cmd === 'resolve') {
    $dir = $argv[2] ?? '';
    if ($dir === '' || !is_dir($dir)) { fwrite(STDERR, "core.php resolve <site-dir>\n"); exit(2); }
    echo resolve_site($dir)['tag'];
    exit(0);
}
// One enumeration of ~/Covey, consumed by `covey sync` and `covey sites` so the
// name rules, version resolution and disabled list cannot drift between them.
// Emits: name \t dir \t tag \t enabled(1|0) \t kind(app|static)
if ($cmd === 'sites') {
    foreach (sites() as $n => $d) {
        printf("%s\t%s\t%s\t%d\t%s\n", $n, $d, resolve_site($d)['tag'],
               site_enabled($n) ? 1 : 0,
               is_file("$d/public/index.php") ? 'app' : 'static');
    }
    exit(0);
}
// Sharing, for bin/covey: one place computes ports and reads systemd.
//   shares          -> name \t port \t state      (every share unit)
//   share-port <n>  -> port
//   share-url <n>   -> url (empty until the tunnel reports one)
//   tunnel          -> name \t bin \t pkg \t args \t url_regex
if ($cmd === 'shares') {
    foreach (shares() as $n => $st) printf("%s\t%d\t%s\n", $n, share_port($n), $st);
    exit(0);
}
if ($cmd === 'share-port') { echo share_port((string)($argv[2] ?? '')), "\n"; exit(0); }
if ($cmd === 'share-url')  { echo share_url((string)($argv[2] ?? '')) ?? '', "\n"; exit(0); }
if ($cmd === 'tunnel') {
    $t = tunnel();
    if (!$t) exit(1);
    echo implode("\t", [$t['name'], $t['bin'], $t['pkg'], $t['args'], $t['url_regex']]), "\n";
    exit(0);
}

// The effective php.ini settings, for `covey sync` to render into each pool.
// Emits: key \t value
if ($cmd === 'ini-check') { exit(ini_valid((string)($argv[2] ?? ''), (string)($argv[3] ?? '')) ? 0 : 1); }
if ($cmd === 'ini') {
    foreach (php_ini() as $k => $v) printf("%s\t%s\n", $k, $v);
    exit(0);
}
if ($cmd === 'status') {
    // Containers cost a ~2s `docker stats` sample; --no-containers skips it.
    $d = status(!in_array('--no-containers', $argv, true));
    if (in_array('--json', $argv, true)) {
        echo json_encode($d, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n";
        exit($d['state'] === 'up' ? 0 : 1);
    }
    exit(render_status($d));
}
if ($cmd === 'doctor') {
    // --cached [ttl]: serve a recent result instead of re-running HTTP checks.
    // Intended for the bar module, which polls far faster than checks change.
    $cached = in_array('--cached', $argv, true);
    $ttl = 10;
    foreach ($argv as $i => $a) if ($a === '--cached' && isset($argv[$i+1]) && ctype_digit($argv[$i+1])) $ttl = (int)$argv[$i+1];
    $cacheFile = "$RUNTIME/covey/doctor.json";
    if ($cached && is_file($cacheFile) && (time() - filemtime($cacheFile)) < $ttl) {
        $raw = (string)file_get_contents($cacheFile);
        $prev = json_decode($raw, true);
        if (is_array($prev)) {
            if (in_array('--json', $argv, true)) { echo $raw; exit($prev['ok'] ? 0 : 1); }
            exit(render_human($prev));
        }
    }
    $d = doctor(in_array('--resources', $argv, true));
    if ($cached) {
        @mkdir(dirname($cacheFile), 0700, true);
        @file_put_contents($cacheFile, json_encode($d, JSON_UNESCAPED_SLASHES) . "\n");
    }
    if (in_array('--json', $argv, true)) {
        echo json_encode($d, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n";
        exit($d['ok'] ? 0 : 1);
    }
    exit(render_human($d));
}
fwrite(STDERR, "usage: core.php [resolve <dir>|sites|doctor [--json] [--resources]|status [--json]]\n");
exit(2);
