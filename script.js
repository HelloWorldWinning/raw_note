/*! Minimalist Web Notepad | https://github.com/pereorga/minimalist-web-notepad
 *  Optimized save loop: event-driven, debounced, raw (gzip for big notes),
 *  only marks "saved" on HTTP 2xx, warns before closing with unsaved changes.
 */
(function () {
    'use strict';

    var IDLE_MS    = 600;        // save this long after the last keystroke / paste
    var RETRY_MIN  = 2000;       // first retry delay after a failed save
    var RETRY_MAX  = 30000;      // retry delay cap
    var GZIP_MIN   = 32 * 1024;  // gzip bodies at or above this many characters

    var textarea  = document.getElementById('content');
    var printable = document.getElementById('printable');
    var baseTitle = document.title;
    var canGzip   = typeof CompressionStream === 'function';

    var dirty = false;   // textarea changed since the last successful save started
    var saving = false;  // a request is in flight
    var timer = null;
    var retryDelay = RETRY_MIN;

    // Title prefix shows state:  "• note" = unsaved,  "⚠ note" = save failing.
    function setState(prefix) {
        document.title = prefix ? prefix + ' ' + baseTitle : baseTitle;
    }

    function schedule(ms) {
        clearTimeout(timer);
        timer = setTimeout(save, ms);
    }

    // Only the 'input' event marks the note dirty: no full-string comparison
    // of a huge textarea every second.
    textarea.addEventListener('input', function () {
        dirty = true;
        setState('•');
        if (!saving) schedule(IDLE_MS);
    });

    function buildBody(text) {
        if (canGzip && text.length >= GZIP_MIN) {
            var gz = new Blob([text]).stream().pipeThrough(new CompressionStream('gzip'));
            return new Response(gz).blob().then(function (blob) {
                return { body: blob, gzip: true };
            });
        }
        return Promise.resolve({ body: text, gzip: false });
    }

    function save() {
        if (!dirty || saving) return;
        saving = true;
        dirty = false;
        var text = textarea.value;

        buildBody(text).then(function (b) {
            var headers = { 'Content-Type': 'text/plain; charset=UTF-8' };
            if (b.gzip) headers['X-Content-Gzip'] = '1';
            return fetch(window.location.href, {
                method: 'POST',
                headers: headers,
                body: b.body,
                cache: 'no-store'
            });
        }).then(function (res) {
            if (!res.ok) throw new Error('HTTP ' + res.status);
            saving = false;
            retryDelay = RETRY_MIN;
            // Tell token_badge.js the saved file changed (it re-counts it).
            window.dispatchEvent(new CustomEvent('note-saved'));
            if (dirty) {
                schedule(IDLE_MS);   // user typed during the request
            } else {
                setState('');
            }
        }).catch(function () {
            saving = false;
            dirty = true;            // keep the change; try again later
            setState('⚠');
            schedule(retryDelay);
            retryDelay = Math.min(retryDelay * 2, RETRY_MAX);
        });
    }

    // Warn before leaving with unsaved changes.
    window.addEventListener('beforeunload', function (e) {
        if (dirty || saving) {
            e.preventDefault();
            e.returnValue = '';
        }
    });

    // Fill the print copy only when printing, instead of keeping a second
    // full copy of the note in the DOM at all times.
    window.addEventListener('beforeprint', function () {
        printable.textContent = textarea.value;
    });
    window.addEventListener('afterprint', function () {
        printable.textContent = '';
    });

    textarea.focus({ preventScroll: true });
})();
