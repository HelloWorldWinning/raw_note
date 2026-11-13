<?php
// count.php
// Token counts for one SAVED note, for token_badge.js.
//   GET count.php?note=<name>  ->  {"o": <int>, "anthropic": <int>}
// The browser sends only the note name. The tokenizer container reads the
// saved file itself (read-only mount), so the note text is never re-uploaded.
// Status codes are passed through from the tokenizer: 200, 400, 404, 413.
// 502 = tokenizer container unreachable.

header('Cache-Control: no-store');
header('Content-Type: application/json');

if ($_SERVER['REQUEST_METHOD'] !== 'GET') {
    http_response_code(405);
    exit('{"error":"GET only"}');
}

// Same rule as index.php.
$note = $_GET['note'] ?? '';
if (!is_string($note) || !preg_match('/^[a-zA-Z0-9_-]+$/', $note) || strlen($note) > 64) {
    http_response_code(400);
    exit('{"error":"bad note name"}');
}

$base = rtrim(getenv('TOKENIZER_URL') ?: 'http://tokenizer:6969', '/');

$ch = curl_init($base . '/count/' . $note);
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
echo $resp;
