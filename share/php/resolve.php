<?php
// covey: pick the best available PHP series for a composer constraint.
// usage: resolve.php "<constraint>" <version>...   prints chosen version or nothing.
// Supports the forms that actually appear in composer.json: ^ ~ >= > <= < = != X.Y.* and ||.

function norm(string $v): string {
    $p = array_map('intval', array_pad(explode('.', trim($v)), 3, 0));
    return "{$p[0]}.{$p[1]}.{$p[2]}";
}

function term_ok(string $t, string $v): bool {
    $t = trim($t);
    if ($t === '' || $t === '*') return true;

    if (preg_match('/^\^\s*(.+)$/', $t, $m)) {          // ^8.2 -> >=8.2.0 <9.0.0
        $b = explode('.', trim($m[1]));
        $lo = norm($m[1]);
        $hi = ((int)$b[0] > 0)
            ? ((int)$b[0] + 1) . '.0.0'
            : '0.' . ((int)($b[1] ?? 0) + 1) . '.0';
        return version_compare($v, $lo, '>=') && version_compare($v, $hi, '<');
    }
    if (preg_match('/^~\s*(.+)$/', $t, $m)) {           // ~8.2 -> >=8.2 <9.0 ; ~8.2.1 -> >=8.2.1 <8.3.0
        $b = explode('.', trim($m[1]));
        $lo = norm($m[1]);
        $hi = (count($b) >= 3)
            ? $b[0] . '.' . ((int)$b[1] + 1) . '.0'
            : ((int)$b[0] + 1) . '.0.0';
        return version_compare($v, $lo, '>=') && version_compare($v, $hi, '<');
    }
    if (preg_match('/^(\d+)\.(\d+)\.\*$/', $t, $m)) {   // 8.2.*
        return version_compare($v, "{$m[1]}.{$m[2]}.0", '>=')
            && version_compare($v, $m[1] . '.' . ((int)$m[2] + 1) . '.0', '<');
    }
    if (preg_match('/^(>=|<=|!=|>|<|=)\s*(.+)$/', $t, $m)) {
        return version_compare($v, norm($m[2]), $m[1] === '=' ? '==' : $m[1]);
    }
    // Bare "8.3" means that series.
    $b = explode('.', $t);
    if (count($b) === 2) {
        return version_compare($v, norm($t), '>=')
            && version_compare($v, $b[0] . '.' . ((int)$b[1] + 1) . '.0', '<');
    }
    return version_compare($v, norm($t), '==');
}

function satisfies(string $constraint, string $v): bool {
    foreach (explode('||', $constraint) as $alt) {          // any alternative
        $ok = true;
        foreach (preg_split('/[,\s]+/', trim($alt), -1, PREG_SPLIT_NO_EMPTY) as $t) {
            if (!term_ok($t, $v)) { $ok = false; break; }   // all terms
        }
        if ($ok) return true;
    }
    return false;
}

$constraint = $argv[1] ?? '';
$cands = array_slice($argv, 2);
usort($cands, fn($a, $b) => version_compare($b, $a));       // highest first
foreach ($cands as $c) {
    if (satisfies($constraint, $c)) { echo $c; exit(0); }
}
exit(1);
