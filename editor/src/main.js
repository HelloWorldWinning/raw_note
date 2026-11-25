/*! raw_note editor: CodeMirror 6 (MIT, https://codemirror.net) in place of
 *  the note textarea.
 *
 *  Why: a <textarea> holds the whole note as one text block. With a big note
 *  (e.g. 1.5 MB), every Chinese IME composition step makes the browser
 *  reprocess the whole block, so typing Chinese lags and freezes.
 *  CodeMirror keeps only the visible lines in the page, so typing costs the
 *  same in a 1 KB note and a 2 MB note.
 *
 *  Behaves like the textarea: Enter inserts a plain newline, Backspace deletes
 *  one character, Tab moves focus, no auto-indent, no spellcheck. Adds Cmd/Ctrl+F
 *  search (needed: the browser's own find only sees lines on screen).
 *
 *  Search panel extras (matchCounter below):
 *    - "current/total" inside the right end of the Find field, e.g. 3/23
 *      (like the browser's own find bar). 0/23 = 23 matches, the cursor is
 *      not on one of them. It takes no space in the panel row, so the
 *      buttons never move.
 *    - "bad regex" in red (and a red Find field) when "regexp" is ticked
 *      and the pattern does not compile; hover it for the browser's message.
 *    - A jump to a match keeps a few lines of context above / below it
 *      instead of landing on the window edge (scrollToMatch).
 *
 *  Progressive enhancement: index.php still prints the note into the
 *  textarea. This script replaces it and exposes window.rawNoteEditor for
 *  script.js. If this script fails to load or throws, the textarea stays
 *  and everything works as before.
 *
 *  Build: cd editor && npm ci && npm run build   (writes ../editor.js)
 */
import { EditorState } from '@codemirror/state';
import { EditorView, ViewPlugin, keymap } from '@codemirror/view';
import {
  history, historyKeymap, standardKeymap,
  insertNewline, deleteCharBackwardStrict,
} from '@codemirror/commands';
import {
  search, searchKeymap, searchPanelOpen, getSearchQuery,
} from '@codemirror/search';

// ---- search panel: match counter + invalid regex feedback -----------------

var COUNT_MAX = 100000;    // stop counting here and show "100000+"
var QUERY_DELAY_MS = 100;  // recount this long after the Find query changed
var DOC_DELAY_MS = 400;    // ... or after the last edit of the note
var CHUNK_CHARS = 32768;   // count about this much text per step
var SLICE_MS = 10;         // then yield to the browser after this long

// Same flags as @codemirror/search, so the message matches its own check.
var RE_FLAGS = 'gm' + (/x/.unicode == null ? '' : 'u');
// Regexes @codemirror/search runs with its multi-line cursor (copied from
// its RegExpCursor). Their matches can cross lines, so they are counted in
// one go instead of line-aligned chunks.
var MULTILINE_RE = /\\[sWDnr]|\n|\r|\[\^/;
// A plain-text query can only cross lines if it holds a line break: a real
// one, or (when not "literal") the \n / \r escapes the panel understands.
var MULTILINE_TEXT = /[\n\r]/;
var MULTILINE_ESC = /\\[nr]/;

function regexpError(source) {
  try {
    new RegExp(source, RE_FLAGS);
    return 'invalid regular expression';
  } catch (e) {
    return (e && e.message) || 'invalid regular expression';
  }
}

// Counting uses CodeMirror's own search cursor, so the total always agrees
// with what next / previous visit. It runs only while the search panel is
// open, starts after a short pause, and works in chunks that end at line
// ends (no match of a single-line query crosses a line end), yielding to
// the browser between chunks: typing in a 2 MB note never waits for it.
// A cursor move only does a binary search over the stored match positions.
var matchCounter = ViewPlugin.fromClass(class {
  constructor(view) {
    this.view = view;
    this.el = null;      // zero-width <span> right after the Find field
    this.text = null;    // the "3/23" <span> inside it
    this.field = null;   // the Find <input>
    this.froms = [];     // start of every match, ascending
    this.tos = [];       // end of every match
    this.capped = false; // stopped at COUNT_MAX
    this.error = '';     // regex error message, '' = none
    this.stale = true;   // positions are for an older text or query
    this.job = null;     // the count in progress
    this.timer = null;
    if (searchPanelOpen(view.state)) this.schedule(QUERY_DELAY_MS);
  }

  update(u) {
    if (!searchPanelOpen(u.state)) {
      if (this.el || this.timer || this.job) this.reset();
      return;
    }
    var queryChanged = !searchPanelOpen(u.startState) ||
      !getSearchQuery(u.state).eq(getSearchQuery(u.startState));
    if (queryChanged || u.docChanged) {
      this.stale = true;
      this.schedule(queryChanged ? QUERY_DELAY_MS : DOC_DELAY_MS);
    } else if (u.selectionSet && !this.stale) {
      this.render();
    }
  }

  // (Re)start the count after `ms`; drops any count in progress.
  schedule(ms) {
    var self = this;
    clearTimeout(this.timer);
    this.job = null;
    this.timer = setTimeout(function () { self.start(); }, ms);
  }

  reset() {
    clearTimeout(this.timer);
    this.timer = null;
    this.job = null;
    this.froms = [];
    this.tos = [];
    this.stale = true;
    this.el = null;      // the panel DOM is gone; a new panel gets a new span
    this.text = null;
    this.field = null;
  }

  start() {
    this.timer = null;
    var state = this.view.state;
    if (!searchPanelOpen(state)) return;
    var q = getSearchQuery(state);
    var job = {
      state: state, q: q, pos: 0, froms: [], tos: [], capped: false, error: '',
      chunked: q.regexp ? !MULTILINE_RE.test(q.search) : !MULTILINE_TEXT.test(q.search) &&
        (q.literal || !MULTILINE_ESC.test(q.search)),
    };
    this.job = job;
    if (!q.valid) {
      if (q.regexp && q.search) job.error = regexpError(q.search);
      this.finish(job);
    } else {
      this.step(job);
    }
  }

  step(job) {
    if (this.job !== job) return;   // replaced by a newer count
    var doc = job.state.doc;
    var deadline = performance.now() + SLICE_MS;
    while (job.pos <= doc.length) {
      var to = job.chunked ? doc.lineAt(Math.min(job.pos + CHUNK_CHARS, doc.length)).to : doc.length;
      var cur = job.q.getCursor(job.state, job.pos, to);
      for (var m = cur.next(); !m.done; m = cur.next()) {
        if (job.froms.length >= COUNT_MAX) { job.capped = true; break; }
        job.froms.push(m.value.from);
        job.tos.push(m.value.to);
      }
      if (job.capped) break;
      job.pos = to + 1;               // start of the next line
      if (job.pos <= doc.length && performance.now() > deadline) {
        var self = this;
        this.timer = setTimeout(function () { self.timer = null; self.step(job); }, 0);
        return;
      }
    }
    this.finish(job);
  }

  finish(job) {
    this.job = null;
    this.froms = job.froms;
    this.tos = job.tos;
    this.capped = job.capped;
    this.error = job.error;
    this.stale = false;
    this.render();
  }

  // 1-based index of the match that equals the main selection, 0 = none.
  current() {
    var sel = this.view.state.selection.main;
    var a = this.froms, lo = 0, hi = a.length - 1;
    while (lo <= hi) {
      var mid = (lo + hi) >> 1;
      if (a[mid] < sel.from) lo = mid + 1;
      else if (a[mid] > sel.from) hi = mid - 1;
      else return this.tos[mid] === sel.to ? mid + 1 : 0;
    }
    return 0;
  }

  // Put the counter right after the Find field. The outer span is 0 px wide
  // (no layout change at all); the text inside it is positioned to the left,
  // over the field's right padding, which the theme reserves for it.
  attach() {
    if (this.el && this.el.isConnected) return true;
    var panel = this.view.dom.querySelector('.cm-search');
    var field = panel && panel.querySelector('[main-field]');
    if (!field) return false;
    if (!this.el) {
      this.el = document.createElement('span');
      this.el.className = 'cm-search-count';
      this.el.setAttribute('aria-hidden', 'true');
      this.text = document.createElement('span');
      this.text.className = 'cm-search-count-text';
      this.el.appendChild(this.text);
    }
    field.insertAdjacentElement('afterend', this.el);
    this.field = field;
    return true;
  }

  render() {
    if (!this.attach()) return;
    var q = getSearchQuery(this.view.state);
    var text = '', title = '';
    if (this.error) {
      text = 'bad regex';
      title = this.error;
    } else if (q.valid) {
      var total = this.froms.length;
      var cur = this.current();
      text = (this.capped && !cur ? '?' : cur) + '/' + total + (this.capped ? '+' : '');
    }
    if (this.text.textContent !== text) this.text.textContent = text;
    if (title) this.field.title = title;
    else this.field.removeAttribute('title');
    this.text.classList.toggle('cm-search-count-bad', !!this.error);
    this.field.classList.toggle('cm-search-bad', !!this.error);
  }

  destroy() {
    clearTimeout(this.timer);
    this.job = null;
    if (this.el) this.el.remove();
  }
});

// A jump to a match keeps ~5 lines of context above / below it. A match that
// is already well inside the window does not scroll at all.
function scrollToMatch(range, view) {
  return EditorView.scrollIntoView(range, {
    y: 'nearest',
    yMargin: Math.round(view.defaultLineHeight * 5),
  });
}

// ---- editor ---------------------------------------------------------------

(function () {
  'use strict';

  var textarea = document.getElementById('content');
  if (!textarea) return;

  var readOnly = textarea.readOnly;
  var listeners = [];

  var view = new EditorView({
    state: EditorState.create({
      doc: textarea.value,
      extensions: [
        EditorState.readOnly.of(readOnly),
        EditorView.editable.of(!readOnly),
        // Custom commands such as insertNewline can dispatch changes directly.
        // Block document changes too, while allowing selection/search updates.
        EditorState.changeFilter.of(function () { return !readOnly; }),
        // Keep keyboard selection, copying and search available when read-only.
        EditorView.contentAttributes.of(readOnly ? { tabindex: '0', 'aria-readonly': 'true' } : {}),
        history(),
        search({ top: true, scrollToMatch: scrollToMatch }),
        matchCounter,
        keymap.of([
          // Plain-textarea behaviour first, so these win over standardKeymap.
          { key: 'Enter', run: insertNewline },
          { key: 'Backspace', run: deleteCharBackwardStrict },
        ].concat(searchKeymap, historyKeymap, standardKeymap)),
        EditorView.lineWrapping,
        // Layout the editor needs to work, kept here and not only in
        // styles.css: a stale cached styles.css must not break scrolling.
        //   height 100%  -> editor fills the window and scrolls inside;
        //                   without it the editor is as tall as the whole
        //                   note, the page cannot scroll, the cursor goes
        //                   off screen.
        //   outline none -> no dotted focus box (CodeMirror's default).
        EditorView.theme({
          '&': { height: '100%' },
          '&.cm-focused': { outline: 'none' },
          '.cm-scroller': { overflow: 'auto', overscrollBehavior: 'none' },
          '.cm-content': { paddingTop: '5px', paddingBottom: '5px' },
          '.cm-line': { paddingLeft: '10px', paddingRight: '10px' },
          // Search panel extras (see matchCounter). All sizes are in the
          // Find field's em (both use font-size 70% of the panel).
          //   Find field: right padding reserved for the counter; set by
          //   CSS from the start, so it never changes while you search.
          //   The Replace field gets the same width, so the two rows
          //   still line up (next above replace).
          '.cm-search [main-field], .cm-search input[name=replace]': { paddingRight: '5.5em' },
          //   Counter: 0 px wide and 0 px tall, centred on the same middle
          //   line as the field (both vertical-align middle).
          '.cm-search-count': {
            display: 'inline-block',
            position: 'relative',
            width: '0',
            height: '0',
            verticalAlign: 'middle',
            fontSize: '70%',
            pointerEvents: 'none',
          },
          //   Text: right edge inside the field; offset = field margin
          //   (.6em) + border (1px) + gap (.5em).
          '.cm-search-count-text': {
            position: 'absolute',
            right: 'calc(1.1em + 1px)',
            top: '0',
            transform: 'translateY(-50%)',
            whiteSpace: 'nowrap',
            fontVariantNumeric: 'tabular-nums',
            opacity: '0.6',
          },
          '.cm-search-count-bad': { color: '#e5484d', opacity: '1' },
          '.cm-textfield.cm-search-bad': {
            borderColor: '#e5484d',
            outline: '1px solid #e5484d',
          },
        }),
        EditorState.tabSize.of(8),   // textarea default
        EditorView.contentAttributes.of({
          spellcheck: 'false',
          autocorrect: 'off',
          autocapitalize: 'off',
          translate: 'no',
        }),
        EditorView.updateListener.of(function (u) {
          if (!u.docChanged) return;
          for (var i = 0; i < listeners.length; i++) listeners[i]();
        }),
      ],
    }),
  });

  view.dom.id = 'editor';
  textarea.parentNode.insertBefore(view.dom, textarea);
  textarea.remove();   // frees the second full copy of the note

  window.rawNoteEditor = {
    // script.js runs after the original textarea has been removed.
    readOnly: readOnly,
    // Full text. Builds a string from the document, so call it only when
    // needed (on save / print), not on every keystroke.
    getValue: function () { return view.state.doc.toString(); },
    // fn() runs after every change of the text.
    onChange: function (fn) { listeners.push(fn); },
    focus: function () { view.focus(); },
    view: view,
  };
})();
