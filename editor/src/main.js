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
 *  Progressive enhancement: index.php still prints the note into the
 *  textarea. This script replaces it and exposes window.rawNoteEditor for
 *  script.js. If this script fails to load or throws, the textarea stays
 *  and everything works as before.
 *
 *  Build: cd editor && npm ci && npm run build   (writes ../editor.js)
 */
import { EditorState } from '@codemirror/state';
import { EditorView, keymap } from '@codemirror/view';
import {
  history, historyKeymap, standardKeymap,
  insertNewline, deleteCharBackwardStrict,
} from '@codemirror/commands';
import { search, searchKeymap } from '@codemirror/search';

(function () {
  'use strict';

  var textarea = document.getElementById('content');
  if (!textarea) return;

  var listeners = [];

  var view = new EditorView({
    state: EditorState.create({
      doc: textarea.value,
      extensions: [
        history(),
        search({ top: true }),
        keymap.of([
          // Plain-textarea behaviour first, so these win over standardKeymap.
          { key: 'Enter', run: insertNewline },
          { key: 'Backspace', run: deleteCharBackwardStrict },
        ].concat(searchKeymap, historyKeymap, standardKeymap)),
        EditorView.lineWrapping,
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
    // Full text. Builds a string from the document, so call it only when
    // needed (on save / print), not on every keystroke.
    getValue: function () { return view.state.doc.toString(); },
    // fn() runs after every change of the text.
    onChange: function (fn) { listeners.push(fn); },
    focus: function () { view.focus(); },
    view: view,
  };
})();
