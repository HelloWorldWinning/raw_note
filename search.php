<?php

// Path to the directory to save the notes in, without trailing slash.
$save_path = getenv('MWN_SAVE_PATH') ?: '_tmp';
$base_url = getenv('MWN_BASE_URL') ?: '';

// Disable caching.
header('Cache-Control: no-cache, no-store, must-revalidate');
header('Pragma: no-cache');
header('Expires: 0');

$query = isset($_GET['q']) ? trim($_GET['q']) : '';
$title_results = [];
$content_results = [];

if ($query !== '') {
    // Get all note files
    $files = glob($save_path . '/*');
    
    foreach ($files as $file) {
        // Skip directories and .htaccess
        if (is_dir($file) || basename($file) === '.htaccess') {
            continue;
        }
        
        $note_name = basename($file);
        $note_content = file_get_contents($file);
        
        // Step 1: Search titles (filenames)
        if (stripos($note_name, $query) !== false) {
            $title_results[] = [
                'name' => $note_name,
                'preview' => mb_substr($note_content, 0, 100)
            ];
        }
        // Step 2: Search content
        elseif (stripos($note_content, $query) !== false) {
            // Find the position and extract context
            $pos = stripos($note_content, $query);
            $start = max(0, $pos - 50);
            $preview = mb_substr($note_content, $start, 150);
            
            $content_results[] = [
                'name' => $note_name,
                'preview' => $preview
            ];
        }
    }
}
?><!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Search Notes</title>
    <link rel="shortcut icon" href="<?php print $base_url; ?>/favicon.ico">
    <style>
        /* =========================================
           Base Reset & Layout
           ========================================= */
        body { 
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; 
            background: #f4f4f5; 
            padding: 40px 20px; 
            margin: 0; 
            color: #111; 
        }
        .container { 
            max-width: 800px; 
            margin: 0 auto; 
        }

        h1 {
            font-size: 24px;
            margin-bottom: 25px;
            /* Color removed to remain neutral/default */
        }

        h2 { 
            font-size: 14px; 
            text-transform: uppercase; 
            color: #888; 
            margin-top: 40px; 
            margin-bottom: 15px; 
            border-bottom: 1px solid #e0e0e0; 
            padding-bottom: 10px;
            letter-spacing: 0.5px;
        }

        /* =========================================
           Search Form Styling
           ========================================= */
        .search-form {
            margin-bottom: 40px;
            display: flex;
            gap: 10px;
        }
        .search-input {
            flex-grow: 1;
            padding: 12px 15px;
            font-size: 16px;
            border: 1px solid #ddd;
            border-radius: 6px;
            box-shadow: 0 1px 2px rgba(0,0,0,0.05);
            outline: none;
            transition: border-color 0.2s;
        }
        .search-input:focus {
            border-color: #999; /* Neutral grey focus */
        }
        .search-button {
            padding: 12px 25px;
            font-size: 16px;
            background: #1f2937;
            color: white;
            border: none;
            border-radius: 6px;
            cursor: pointer;
            font-weight: 500;
            transition: background 0.2s;
        }
        .search-button:hover {
            background: #000;
        }
        .back-link {
            display: inline-block;
            margin-top: 30px;
            color: #666;
            text-decoration: none;
            font-size: 14px;
        }
        .back-link:hover { text-decoration: underline; }

        /* =========================================
           List Group & Items (New Style)
           ========================================= */
        .list-group { 
            background: white; 
            border-radius: 8px; 
            box-shadow: 0 4px 12px rgba(0,0,0,0.05); 
            overflow: hidden; 
        }

        .list-item { 
            display: flex; 
            flex-direction: column; 
            padding: 18px 25px; 
            text-decoration: none; 
            color: inherit; 
            border-bottom: 1px solid #f0f0f0; 
            transition: background 0.1s ease-in-out; 
            border-left-style: solid;
            border-left-width: 6px; 
        }
        .list-item:last-child { border-bottom: none; }
        .list-item:hover { background: #fbfbfb; }

        .title { 
            font-size: 16px; 
            font-weight: 600; 
            margin-bottom: 6px; 
            color: #1f2937;
            display: block; 
        }
        
        .snippet { 
            font-size: 14px; 
            color: #6b7280; 
            line-height: 1.5;
            display: block; 
            white-space: nowrap; 
            overflow: hidden; 
            text-overflow: ellipsis; 
        }
        
        .highlight { 
            background: #fef08a; /* Soft yellow highlight */
            color: #000; 
            padding: 0 2px; 
            border-radius: 2px; 
        }
        .no-results { color: #666; font-style: italic; margin-top: 10px; }

        /* =========================================
           STYLE 1: Electric & Vivid (Magenta vs Cyan)
           ========================================= */
        /* Magenta for Titles */
        .style1-title { border-left-color: #d946ef; } 
        /* Cyan for Content */
        .style1-content { border-left-color: #06b6d4; } 

    </style>
</head>
<body>
    <div class="container">
        <h1>🔍 Search Notes</h1>
        
        <form class="search-form" method="get" action="<?php print $base_url; ?>/search">
            <input type="text" name="q" class="search-input" 
                   value="<?php print htmlspecialchars($query, ENT_QUOTES, 'UTF-8'); ?>" 
                   placeholder="Enter search term..." autofocus>
            <button type="submit" class="search-button">Search</button>
        </form>

        <?php if ($query !== ''): ?>
            
            <?php if (!empty($title_results)): ?>
                <h2>Title Matches (<?php print count($title_results); ?>)</h2>
                <div class="list-group">
                    <?php foreach ($title_results as $result): ?>
                        <a href="<?php print $base_url . '/' . htmlspecialchars($result['name'], ENT_QUOTES, 'UTF-8'); ?>" class="list-item style1-title">
                            <span class="title">
                                <?php 
                                    $highlighted = preg_replace(
                                        '/(' . preg_quote($query, '/') . ')/i', 
                                        '<span class="highlight">$1</span>', 
                                        htmlspecialchars($result['name'], ENT_QUOTES, 'UTF-8')
                                    );
                                    print $highlighted;
                                ?>
                            </span>
                            <span class="snippet">
                                <?php print htmlspecialchars($result['preview'], ENT_QUOTES, 'UTF-8'); ?>
                                <?php if (strlen($result['preview']) >= 100): ?>...<?php endif; ?>
                            </span>
                        </a>
                    <?php endforeach; ?>
                </div>
            <?php endif; ?>

            <?php if (!empty($content_results)): ?>
                <h2>Content Matches (<?php print count($content_results); ?>)</h2>
                <div class="list-group">
                    <?php foreach ($content_results as $result): ?>
                        <a href="<?php print $base_url . '/' . htmlspecialchars($result['name'], ENT_QUOTES, 'UTF-8'); ?>" class="list-item style1-content">
                            <span class="title">
                                <?php print htmlspecialchars($result['name'], ENT_QUOTES, 'UTF-8'); ?>
                            </span>
                            <span class="snippet">
                                ...<?php 
                                    $highlighted = preg_replace(
                                        '/(' . preg_quote($query, '/') . ')/i', 
                                        '<span class="highlight">$1</span>', 
                                        htmlspecialchars($result['preview'], ENT_QUOTES, 'UTF-8')
                                    );
                                    print $highlighted;
                                ?>...
                            </span>
                        </a>
                    <?php endforeach; ?>
                </div>
            <?php endif; ?>

            <?php if (empty($title_results) && empty($content_results)): ?>
                <p class="no-results">No results found for "<?php print htmlspecialchars($query, ENT_QUOTES, 'UTF-8'); ?>".</p>
            <?php endif; ?>

        <?php endif; ?>

        <a href="<?php print $base_url; ?>/" class="back-link">← Create new note</a>
    </div>
</body>
</html>
