/* token_badge.js
 * Token-count badge for Minimalist Web Notepad.
 *
 * Section A is copied unchanged from raw_token_counter.js: it defines the
 * badge's look. To take a style change from a newer raw_token_counter.js,
 * copy its badge block over Section A. Nothing in Section B depends on it
 * except setBadge().
 *
 * Section B fetches counts for the SAVED note from GET /<note>?tokens=1
 * (handled by index.php):
 *   - once when the page opens
 *   - after every successful save ('note-saved' event fired by script.js)
 * The note text is never sent; the tokenizer reads the saved file.
 *
 * Badge values:  number = count,  "—" = note not saved yet / empty,
 *                "too big" = note over the tokenizer's size limit,
 *                "err 502" etc. = server answered with that HTTP status
 *                  (502 = tokenizer container down or unreachable),
 *                "err net" = request never got an answer: network down,
 *                  timeout, or blocked inside the browser by an extension,
 *                "err json" = HTTP 200 but the body was not JSON.
 * The next save retries in every error case. Details go to the console.
 *
 * index.php passes the URL as a data attribute on this script tag:
 * data-tokens-url.
 */
(function () {
  'use strict';

  const me = document.currentScript;
  const TOKENS_URL = me && me.dataset.tokensUrl;
  if (!TOKENS_URL) return;

  // ===== Section A: badge (copied unchanged from raw_token_counter.js) =====

  const badge = document.createElement('div');
  badge.id = 'tc-token-badge';

  const num1 = document.createElement('span');
  const num2 = document.createElement('span');

  num1.id = 'tc-token-o';
  num2.id = 'tc-token-anthropic';

  badge.appendChild(num1);
  badge.appendChild(num2);

  Object.assign(badge.style, {
    position: 'fixed',
    top: '11%',
    right: '0px',
    transform: 'translateY(-50%)',
    zIndex: '999999',
    pointerEvents: 'none',
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'stretch',
    whiteSpace: 'nowrap',
    overflow: 'hidden',
    padding: '0',
    borderRadius: '15px 0 0 15px',
    boxShadow: '0 3px 10px rgba(0,0,0,0.08)',
    fontSize: '19px',
    fontWeight: 'bold',
    fontFamily: 'sans-serif'
  });

  Object.assign(num1.style, {
    background: '#7048e8',
    color: '#ffffff',
    paddingTop: '1.5px',
    paddingBottom: '0px',
    paddingLeft: '8px',
    paddingRight: '4px'
  });

  Object.assign(num2.style, {
    background: '#ae3ec9',
    color: '#ffffff',
    paddingTop: '0px',
    paddingBottom: '0px',
    paddingLeft: '8px',
    paddingRight: '4px'
  });

  num1.textContent = '—';
  num2.textContent = '—';

  // Appended to <html>, NOT <body>: styles.css has a "body * { ... !important }"
  // rule that would override the badge's font, weight and line height.
  document.documentElement.appendChild(badge);

  // Hide badge while the mouse is over it
  document.addEventListener('mousemove', (e) => {
    const r = badge.getBoundingClientRect();
    const overBadge =
      e.clientX >= r.left &&
      e.clientX <= r.right &&
      e.clientY >= r.top &&
      e.clientY <= r.bottom;
    badge.style.opacity = overBadge ? '0' : '1';
  });

  function setBadge(oText, aText) {
    num1.textContent = oText;
    num2.textContent = aText;
  }

  // ===== Section B: counts for the saved note =====

  // Must be longer than index.php's 30 s curl timeout.
  const TIMEOUT_MS = 35000;

  let inFlight = false; // a count request is running
  let pending = false;  // a save happened while busy or hidden: fetch once more

  function fmt(v) {
    return typeof v === 'number' ? v.toLocaleString('en-US') : '?';
  }

  function refresh() {
    if (inFlight || document.hidden) {
      pending = true;
      return;
    }
    inFlight = true;
    pending = false;

    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), TIMEOUT_MS);

    fetch(TOKENS_URL, {
      cache: 'no-store',
      signal: ctrl.signal
    })
      .then((res) => {
        if (res.status === 404) { setBadge('—', '—'); return; }
        if (res.status === 413) { setBadge('too big', 'too big'); return; }
        if (!res.ok) {
          return res.text().then((t) => {
            console.warn('[token_badge] HTTP ' + res.status, t);
            setBadge('err ' + res.status, 'err ' + res.status);
          });
        }
        return res.json().then((j) => setBadge(fmt(j.o), fmt(j.anthropic)));
      })
      .catch((e) => {
        if (e && e.name === 'SyntaxError') {
          // HTTP 200 but the body was not JSON.
          console.warn('[token_badge] bad JSON from ' + TOKENS_URL, e);
          setBadge('err json', 'err json');
          return;
        }
        // fetch() itself failed: no HTTP answer reached the page.
        console.warn('[token_badge] no answer from ' + TOKENS_URL, e);
        setBadge('err net', 'err net');
      })
      .finally(() => {
        clearTimeout(timer);
        inFlight = false;
        if (pending) refresh();
      });
  }

  window.addEventListener('note-saved', refresh);
  document.addEventListener('visibilitychange', () => {
    if (!document.hidden && pending) refresh();
  });

  refresh();
})();
