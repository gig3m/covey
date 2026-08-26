<?php
// covey core: provider registry, PHP version resolution, and the check model.
// Both `covey sync` and `covey doctor` go through here so they cannot disagree.
//
// usage: core.php resolve <site-dir>
//        core.php doctor [--json]

const OK = true;

function env_or(string $k, string $d): string { $v = getenv($k); return $v === false || $v === '' ? $d : $v; }

$HOME    = env_or('HOME', '/root');
$COVEY   = env_or('COVEY_HOME',    "$HOME/.local/share/covey");
$SITES   = env_or('COVEY_SITES',   "$HOME/Covey");
$RUNTIME = env_or('XDG_RUNTIME_DIR', '/run/user/' . getmyuid());
$DEFAULT = env_or('COVEY_DEFAULT_PHP', '85');

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
        if (!preg_match('/^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$/', $n)) continue;
        $out[$n] = $dir;
    }
    return $out;
}

// ---- checks ----------------------------------------------------------------
function unit_active(string $u): bool {
    exec('systemctl --user is-active --quiet ' . escapeshellarg($u), $o, $rc);
    return $rc === 0;
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

function platform_checks(): array {
    global $DEFAULT;
    $c = [];
    $c[] = unit_active('covey-caddy.service')
        ? chk('caddy', OK)
        : chk('caddy', false, ['problem'=>'caddy_inactive','detail'=>'web server is not running',
                               'fix'=>fix('covey start')]);

    $needed = [];
    foreach (sites() as $n => $d) $needed[resolve_site($d)['tag']] = true;
    if (!$needed) $needed[$DEFAULT] = true;
    foreach (array_keys($needed) as $tag) {
        $p = provider($tag);
        $series = $p['series'] ?? $tag;
        if (!tag_installed($tag)) {
            $c[] = chk("php-$series", false, ['problem'=>'provider_not_installed',
                'detail'=>"PHP $series is not installed",
                'fix'=>fix("covey php install $tag", true)]);
            continue;
        }
        $c[] = unit_active("covey-fpm@$tag.service")
            ? chk("php-$series", OK, ['detail'=>tag_version($tag)])
            : chk("php-$series", false, ['problem'=>'pool_inactive',
                'detail'=>"FPM pool for $series is not running", 'fix'=>fix('covey start')]);

        $missing = [];
        $loaded = strtolower((string)@shell_exec(escapeshellarg($p['php']) . ' -m 2>/dev/null'));
        $loaded = preg_split('/\s+/', $loaded, -1, PREG_SPLIT_NO_EMPTY) ?: [];
        foreach (covey_extensions() as $e) if (!in_array(strtolower($e), $loaded, true)) $missing[] = $e;
        $c[] = $missing
            ? chk("extensions-$series", false, ['problem'=>'extensions_missing',
                'detail'=>implode(' ', $missing), 'fix'=>fix("covey php configure $tag", true)])
            : chk("extensions-$series", OK);
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

    exec('docker info >/dev/null 2>&1', $o, $rc);
    if ($rc !== 0) {
        $c[] = chk('docker', false, ['problem'=>'docker_unavailable',
            'detail'=>'docker is not responding', 'fix'=>fix('sudo systemctl start docker', true)]);
        return $c;
    }
    $c[] = chk('docker', OK);
    foreach ([['mysql',3306],['redis',6379],['mailpit',1025]] as [$svc,$port]) {
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

function site_report(string $name, string $dir): array {
    $r = resolve_site($dir);
    $p = provider($r['tag']);
    $checks = [];

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

    $pr = platform_reqs_check($dir, $r['tag']);
    if ($pr !== null) $checks[] = $pr;

    $checks[] = http_check($name);

    $cf = covey_file($dir);
    if (!empty($cf['database'])) {
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

    return ['name'=>$name, 'url'=>"https://$name.localhost", 'path'=>$dir,
            'php'=>['tag'=>$r['tag'], 'series'=>$p['series'] ?? null,
                    'resolved'=>tag_version($r['tag']), 'required'=>$r['required'],
                    'source'=>$r['source']],
            'checks'=>$checks];
}

function doctor(): array {
    $platform = platform_checks();
    $sites = [];
    foreach (sites() as $n => $d) $sites[] = site_report($n, $d);
    $ok = true;
    foreach ($platform as $c) if (!$c['ok']) $ok = false;
    foreach ($sites as $s) foreach ($s['checks'] as $c) if (!$c['ok']) $ok = false;
    return ['ok'=>$ok, 'platform'=>$platform, 'sites'=>$sites];
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
    echo "PLATFORM\n";
    foreach ($d['platform'] as $c) $line($c);
    foreach ($d['sites'] as $s) {
        printf("\n%s  %s\n", $s['name'], $s['url']);
        foreach ($s['checks'] as $c) $line($c);
    }
    if (!$d['sites']) echo "\n(no sites)\n";
    echo "\n" . ($d['ok'] ? "all checks passed\n" : "some checks failed\n");
    return $d['ok'] ? 0 : 1;
}

// ---- entry -----------------------------------------------------------------
$cmd = $argv[1] ?? 'doctor';
if ($cmd === 'resolve') {
    $dir = $argv[2] ?? '';
    if ($dir === '' || !is_dir($dir)) { fwrite(STDERR, "core.php resolve <site-dir>\n"); exit(2); }
    echo resolve_site($dir)['tag'];
    exit(0);
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
    $d = doctor();
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
fwrite(STDERR, "usage: core.php [resolve <dir>|doctor [--json]]\n");
exit(2);
