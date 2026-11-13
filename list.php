<?php

// Path to the directory to save the notes in, without trailing slash.
$save_path = getenv('MWN_SAVE_PATH') ?: '_tmp';
$base_url = getenv('MWN_BASE_URL') ?: '';

// Disable caching.
header('Cache-Control: no-cache, no-store, must-revalidate');
header('Pragma: no-cache');
header('Expires: 0');

$notes = [];

// Get all note files
$files = glob($save_path . '/*');

foreach ($files as $file) {
    // Skip directories and .htaccess
    if (is_dir($file) || basename($file) === '.htaccess') {
        continue;
    }

    $note_name = basename($file);
    $note_content = file_get_contents($file);
    $modified_time = filemtime($file);

    $notes[] = [
        'name' => $note_name,
        'preview' => mb_substr($note_content, 0, 200, 'UTF-8'),
        'size' => strlen($note_content),
        'modified' => $modified_time
    ];
}

// Sort by modified time (newest first)
usort($notes, function($a, $b) {
    return $b['modified'] - $a['modified'];
});

$total_notes = count($notes);

// Human-friendly file size: 512 B, 9.8 KB, 1.4 MB, 2.1 GB
function human_size($bytes) {
    $units = ['B', 'KB', 'MB', 'GB', 'TB'];
    $i = 0;
    $size = (float)$bytes;
    while ($size >= 1024 && $i < count($units) - 1) {
        $size /= 1024;
        $i++;
    }
    if ($i === 0) {
        return $bytes . ' B';
    }
    // 1 decimal below 10 (e.g. 9.8 KB), no decimals from 10 up (e.g. 120 KB)
    return ($size < 10 ? number_format($size, 1) : number_format($size, 0)) . ' ' . $units[$i];
}
?><!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>All Notes</title>
    <link rel="shortcut icon" href="<?php print $base_url; ?>/favicon.ico">
    <link rel="stylesheet" href="<?php print $base_url; ?>/styles.css">
    <style>
        * {
            box-sizing: border-box;
        }
        body {
            margin: 0;
            padding: 0;
            overscroll-behavior: none;
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            background: #f5f5f5;
        }

        .list-container {
            max-width: 1100px;
            margin: 5px auto;
            padding: 10px 15px;
            background: #fff;
            border-radius: 12px;
            box-shadow: 0 2px 12px rgba(0,0,0,0.08);
        }

        .header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 10px;
            flex-wrap: wrap;
            gap: 15px;
        }

        .header h1 {
            margin: 0;
            font-size: 26px;
            font-weight: 600;
            color: #1a1a1a;
        }

        .header-links a {
            margin-left: 20px;
            color: #0066cc;
            text-decoration: none;
            font-size: 15px;
            font-weight: 500;
        }
        .header-links a:first-child {
            margin-left: 0;
        }

        .header-links a:hover {
            text-decoration: underline;
        }

        .stats {
            background: #f8f9fa;
            padding: 12px 18px;
            border-radius: 8px;
            margin-bottom: 10px;
            color: #555;
            font-size: 14px;
            border-left: 4px solid #0066cc;
        }

        .notes-table {
            width: 100%;
            border-collapse: collapse;
        }

        .notes-table thead tr {
            background: #f8f9fa;
            border-bottom: 2px solid #e0e0e0;
        }

        .notes-table th {
            padding: 16px 20px;
            text-align: left;
            font-weight: 600;
            color: #444;
            font-size: 13px;
            text-transform: uppercase;
            letter-spacing: 0.5px;
        }

        .notes-table tbody tr {
            border-bottom: 1px solid #eee;
            transition: background 0.15s ease;
        }

        .notes-table tbody tr:hover {
            background: #f8fbff;
        }

        .notes-table td {
            padding: 20px;
            vertical-align: top;
            color: #333;
        }

        /* Column order (left -> right): Title | Preview | Size | Date
           Importance (used only for hiding order when zooming in):
           Preview > Title > Date > Size
           Preview has no fixed width: it takes all remaining space. */

        /* Preview Column (most important, never hidden).
           The whole cell is clickable: the link's ::after covers the entire td. */
        .col-preview {
            position: relative;
        }
        .note-preview {
            display: block;
            font-size: 14px;
            color: #666;
            line-height: 1.6;
            word-break: break-word;
            text-decoration: none;
            cursor: pointer;
        }
        .note-preview::after {
            content: "";
            position: absolute;
            inset: 0;
        }
        .col-preview:hover .note-preview {
            color: #0052a3;
            text-decoration: underline;
        }
        .empty-preview {
            color: #aaa;
            font-style: italic;
        }

        /* Title Column */
        .col-title {
            width: 22%;
        }
        .note-title {
            font-size: 16px;
            font-weight: 600;
            color: #0066cc;
            text-decoration: none;
            display: block;
            word-break: break-word;
        }
        .note-title:hover {
            color: #0052a3;
            text-decoration: underline;
        }

        /* Date Column */
        .col-date {
            width: 120px;
            white-space: nowrap;
        }
        .note-date {
            font-size: 14px;
            color: #777;
        }
        .note-time {
            font-size: 12px;
            color: #aaa;
            margin-top: 4px;
        }

        /* Size Column (least important) */
        .col-size {
            width: 100px;
            white-space: nowrap;
        }
        .note-size {
            font-size: 14px;
            color: #555;
            font-weight: 500;
        }

        /* Empty State */
        .no-notes {
            text-align: center;
            padding: 60px 20px;
            color: #888;
        }
        .no-notes p {
            margin: 10px 0;
        }
        .no-notes a {
            color: #0066cc;
        }

        /* Responsive: zooming in shrinks the viewport width in CSS pixels,
           so columns are hidden in reverse order of importance:
           Size first -> Date -> Title. Preview is never hidden. */

        /* Step 1: hide Size */
        @media (max-width: 900px) {
            .col-size {
                display: none;
            }
            .notes-table th,
            .notes-table td {
                padding: 15px 12px;
            }
        }

        /* Step 2: hide Date */
        @media (max-width: 700px) {
            .col-date {
                display: none;
            }
            .col-title {
                width: 30%;
            }
        }

        /* Step 3: hide Title (Preview remains as the only column, and is a link) */
        @media (max-width: 500px) {
            .col-title {
                display: none;
            }
            .list-container {
                margin: 5px;
                padding: 10px;
            }
        }
    </style>
</head>
<body>
    <div class="list-container">
        <div class="header">
            <h1>📋 All Notes</h1>
            <div class="header-links">
                <a href="<?php print $base_url; ?>/search">🔍 Search</a>
                <a href="<?php print $base_url; ?>/">+ New Note</a>
            </div>
        </div>

        <div class="stats">
            📊 Total: <strong><?php print $total_notes; ?></strong> note(s)
        </div>

        <?php if (empty($notes)): ?>
            <div class="no-notes">
                <p>No notes yet.</p>
                <p><a href="<?php print $base_url; ?>/">Create your first note →</a></p>
            </div>
        <?php else: ?>
            <table class="notes-table">
                <thead>
                    <tr>
                        <th class="col-title">Title</th>
                        <th class="col-preview">Preview</th>
                        <th class="col-size">Size</th>
                        <th class="col-date">Date</th>
                    </tr>
                </thead>
                <tbody>
                    <?php foreach ($notes as $note):
                        $safe_name = htmlspecialchars($note['name'], ENT_QUOTES, 'UTF-8');
                        $note_url = $base_url . '/' . $safe_name;
                    ?>
                        <tr>
                            <td class="col-title">
                                <a href="<?php print $note_url; ?>" class="note-title"><?php print $safe_name; ?></a>
                            </td>
                            <td class="col-preview">
                                <?php if ($note['size'] > 0): ?>
                                    <a href="<?php print $note_url; ?>" class="note-preview" title="<?php print $safe_name; ?>">
                                        <?php print htmlspecialchars($note['preview'], ENT_QUOTES, 'UTF-8'); ?><?php if ($note['size'] > 200): ?>...<?php endif; ?>
                                    </a>
                                <?php else: ?>
                                    <a href="<?php print $note_url; ?>" class="note-preview empty-preview" title="<?php print $safe_name; ?>">(empty) <?php print $safe_name; ?></a>
                                <?php endif; ?>
                            </td>
                            <td class="col-size">
                                <span class="note-size" title="<?php print number_format($note['size']); ?> bytes"><?php print human_size($note['size']); ?></span>
                            </td>
                            <td class="col-date">
                                <div class="note-date"><?php print date('Y-m-d', $note['modified']); ?></div>
                                <div class="note-time"><?php print date('H:i:s', $note['modified']); ?></div>
                            </td>
                        </tr>
                    <?php endforeach; ?>
                </tbody>
            </table>
        <?php endif; ?>
    </div>
</body>
</html>
