<?php

date_default_timezone_set(getenv('TZ') ?: 'Australia/Perth');
// Base URL of the website, without trailing slash.
$base_url = getenv('MWN_BASE_URL') ?: '';

// Path to the directory to save the notes in, without trailing slash.
// Should be outside of the document root, if possible.
$save_path = getenv('MWN_SAVE_PATH') ?: '_tmp';

// Disable caching.
header('Cache-Control: no-cache, no-store, must-revalidate');
header('Pragma: no-cache');
header('Expires: 0');

// If no name is provided or it contains invalid characters or it is too long.
if (!isset($_GET['note']) || !preg_match('/^[a-zA-Z0-9_-]+$/', $_GET['note']) || strlen($_GET['note']) > 64) {

    // Load the word list.
    $words = @file(
        __DIR__ . '/.Longman_Communication_3000.txt',
        FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES
    );

    if ($words === false) {
        http_response_code(500);
        exit('Cannot read Longman_Communication_3000.txt');
    }

    // Keep unique, lowercase, alphabetic words.
    $words = array_map('trim', $words);
    $words = array_map('strtolower', $words);
    $words = array_values(array_unique(
        preg_grep('/^[a-z]+$/D', $words)
    ));

    if (!$words) {
        http_response_code(500);
        exit('The word list contains no usable words.');
    }

    // Try words in random order, avoiding existing note names.
    shuffle($words);
    $today = date('Y-m-d');

    foreach ($words as $word) {
        $random_name = $today . '-' . $word;
        if (!file_exists($save_path . '/' . $random_name)) {
            header("Location: $base_url/" . $random_name);
            die;
        }
    }

    // Every usable word already has a note for today.
    http_response_code(503);
    exit('No unused note names are available for today.');
}

// Route "search" to the search page
if ($_GET['note'] === 'search') {
    include 'search.php';
    die;
}

// Route "list" to the list page
if ($_GET['note'] === 'list') {
    include 'list.php';
    die;
}

$note = $_GET['note'];
$path = $save_path . '/' . $note;

// ---------------------------------------------------------------------------
// Token counts of this SAVED note, for token_badge.js.
//   GET /<note>?tokens=1  ->  {"o": <int>, "anthropic": <int>}
// Served from the note's own URL on purpose: the old URL "count.php?note=..."
// matches the EasyPrivacy rule "/count.php?", so ad blockers dropped the
// request inside the browser and the badge showed "err".
// The tokenizer reads the saved file itself; the note text is not re-sent.
// Tokenizer status codes are passed through (200, 400, 404, 413).
// 502 = tokenizer unreachable.
// ---------------------------------------------------------------------------
if (isset($_GET['tokens']) && $_SERVER['REQUEST_METHOD'] === 'GET') {
    header('Content-Type: application/json');

    // Which folder of the tokenizer's /notes holds this notepad's files.
    $space = getenv('NOTE_SPACE') ?: 'public';
    $base  = rtrim(getenv('TOKENIZER_URL') ?: 'http://tokenizer:6969', '/');

    $ch = curl_init($base . '/count/' . rawurlencode($space) . '/' . $note);
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_FOLLOWLOCATION => false,
        CURLOPT_CONNECTTIMEOUT => 2,
        CURLOPT_TIMEOUT        => 30,
    ]);
    $resp = curl_exec($ch);

    if ($resp === false) {
        http_response_code(502);
        exit(json_encode(['error' => 'tokenizer unreachable: ' . curl_error($ch)]));
    }

    http_response_code(curl_getinfo($ch, CURLINFO_RESPONSE_CODE));
    exit($resp);
}

// ---------------------------------------------------------------------------
// Save.
// Accepts three body formats:
//   1. Raw text body (what script.js sends):      Content-Type: text/plain
//   2. Raw gzip body (script.js, notes >= 32 KB):  header X-Content-Gzip: 1
//   3. Legacy form field:                          curl -d "text=..."
// ---------------------------------------------------------------------------
if ($_SERVER['REQUEST_METHOD'] === 'POST') {

    $ctype = strtolower($_SERVER['CONTENT_TYPE'] ?? '');

    if (isset($_POST['text'])) {
        $text = $_POST['text'];
    } elseif (strpos($ctype, 'application/x-www-form-urlencoded') === 0
              && strncmp((string)file_get_contents('php://input', false, null, 0, 5), 'text=', 5) === 0) {
        // Form post whose "text" field PHP dropped (body > post_max_size).
        // Refuse instead of saving the raw "text=..." body as the note.
        http_response_code(413);
        exit('Form body larger than post_max_size. Note NOT saved.');
    } else {
        $text = file_get_contents('php://input');

        // When the body exceeds post_max_size, PHP discards it and the read
        // comes back empty. Without this check an oversized paste would be
        // treated as "empty note" and the existing note would be deleted.
        $declared = isset($_SERVER['CONTENT_LENGTH']) ? (int)$_SERVER['CONTENT_LENGTH'] : null;
        if ($text === false || ($declared !== null && strlen($text) !== $declared)) {
            http_response_code(413);
            exit('Body incomplete or larger than post_max_size. Note NOT saved.');
        }

        if (($_SERVER['HTTP_X_CONTENT_GZIP'] ?? '') === '1') {
            $text = gzdecode($text);
            if ($text === false) {
                http_response_code(400);
                exit('Invalid gzip body. Note NOT saved.');
            }
        }
    }

    // Empty input deletes the note.
    if ($text === '') {
        if (is_file($path)) {
            unlink($path);
        }
        exit;
    }

    // Write to a temp file, then rename: a reader never sees a half-written note,
    // and a failed write never truncates the existing note.
    $tmp = $save_path . '/.' . $note . '.' . uniqid('', true) . '.tmp';
    if (file_put_contents($tmp, $text) === false || !rename($tmp, $path)) {
        @unlink($tmp);
        http_response_code(500);
        exit('Write failed. Note NOT saved.');
    }
    exit;
}

// Compress the page / raw output (skipped if PHP or the client can't do gzip).
if (!ini_get('zlib.output_compression')) {
    ob_start('ob_gzhandler');
}

// Print raw file if the client is curl, wget, or when explicitly requested.
$ua = $_SERVER['HTTP_USER_AGENT'] ?? '';
if (isset($_GET['raw']) || strpos($ua, 'curl') === 0 || strpos($ua, 'Wget') === 0) {
    if (is_file($path)) {
        header('Content-type: text/plain; charset=UTF-8');
        readfile($path);
    } else {
        header('HTTP/1.0 404 Not Found');
    }
    die;
}
?><!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta name="generator" content="Minimalist Web Notepad (https://github.com/pereorga/minimalist-web-notepad)">
    <title><?php print $note; ?></title>
    <link rel="shortcut icon" href="<?php print $base_url; ?>/favicon.ico">
    <link rel="stylesheet" href="<?php print $base_url; ?>/styles.css">
</head>
<body>
    <div class="container">
        <textarea id="content" spellcheck="false" autocomplete="off" autocorrect="off" autocapitalize="off"><?php
            if (is_file($path)) {
                print htmlspecialchars(file_get_contents($path), ENT_QUOTES, 'UTF-8');
            }
        ?></textarea>
    </div>
    <pre id="printable"></pre>
    <script src="<?php print $base_url; ?>/editor.js?v=<?php print filemtime(__DIR__ . '/editor.js'); ?>"></script>
    <script src="<?php print $base_url; ?>/script.js?v=<?php print filemtime(__DIR__ . '/script.js'); ?>"></script>
    <script src="<?php print $base_url; ?>/token_badge.js?v=<?php print filemtime(__DIR__ . '/token_badge.js'); ?>"
            data-tokens-url="<?php print $base_url . '/' . $note; ?>?tokens=1"></script>

</body>
</html>
