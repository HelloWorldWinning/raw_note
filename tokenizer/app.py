"""Token-count service for Minimalist Web Notepad.

Endpoints (GET only):
    /health         -> 200 {"ok": true}
    /count/<name>   -> 200 {"o": <int>, "anthropic": <int>}
                       400 bad name, 404 no such note, 413 note too large

The note text is never sent to this service. It reads the SAVED note file
from NOTES_DIR (a read-only mount of the notepad's save folder).

Tokenizers (pin versions in requirements.txt so counts never drift):
    "o"         tiktoken, encoding O_ENCODING (default o200k_base)
    "anthropic" legacy Claude tokenizer.json, the file the anthropic Python
                SDK <= 0.38 used for client.count_tokens()

All vocab files are baked into the image at build time (build_vocab.py),
so this service needs no network access at runtime.
"""

import errno
import json
import os
import re
import stat
import threading
from collections import OrderedDict

import tiktoken
from tokenizers import Tokenizer

NOTES_DIR = os.environ.get("NOTES_DIR", "/notes")
O_ENCODING = os.environ.get("O_ENCODING", "o200k_base")
CLAUDE_TOKENIZER = os.environ.get("CLAUDE_TOKENIZER", "/opt/vocab/claude-tokenizer.json")
MAX_BYTES = int(os.environ.get("MAX_BYTES", str(16 * 1024 * 1024)))
CACHE_ENTRIES = int(os.environ.get("CACHE_ENTRIES", "256"))
# Claude tokenizer memory grows ~180 MB per MB of text, so text is fed in chunks.
CHUNK_CHARS = int(os.environ.get("CHUNK_CHARS", str(256 * 1024)))

# Same rule as index.php: letters, digits, "_" and "-", 1 to 64 characters.
# This also rejects index.php's hidden ".<name>.<id>.tmp" files and ".htaccess".
NAME_RE = re.compile(r"[A-Za-z0-9_-]{1,64}")

# Loaded once in the gunicorn master (--preload); workers share the memory.
ENC_O = tiktoken.get_encoding(O_ENCODING)
ENC_A = Tokenizer.from_file(CLAUDE_TOKENIZER)


class TooLarge(Exception):
    pass


def _safe_cuts(text, size):
    """Yield chunks of `text` cut only where the Claude tokenizer gives the
    same total as encoding the whole text at once.

    A cut is made just before a " " or "\\n" whose previous character is not
    whitespace. At such a point the ByteLevel pre-tokenizer always starts a
    new piece, NFKC normalization cannot join characters across it, and the
    tokenizer adds no special tokens, so the per-chunk counts add up exactly.
    If no such point exists (one huge line with no spaces), the rest of the
    text is encoded as one chunk.
    """
    n = len(text)
    start = 0
    while n - start > size:
        i = start + size
        cut = -1
        while i < n:
            c = text[i]
            if (c == " " or c == "\n") and not text[i - 1].isspace():
                cut = i
                break
            i += 1
        if cut == -1:
            break
        yield text[start:cut]
        start = cut
    yield text[start:]


def count_text(text):
    o = len(ENC_O.encode_ordinary(text))
    a = 0
    for chunk in _safe_cuts(text, CHUNK_CHARS):
        a += len(ENC_A.encode(chunk).ids)
    return {"o": o, "anthropic": a}


_cache = OrderedDict()
_cache_lock = threading.Lock()


def _cache_get(key):
    with _cache_lock:
        val = _cache.get(key)
        if val is not None:
            _cache.move_to_end(key)
        return val


def _cache_put(key, val):
    with _cache_lock:
        _cache[key] = val
        _cache.move_to_end(key)
        while len(_cache) > CACHE_ENTRIES:
            _cache.popitem(last=False)


def count_note(name):
    path = os.path.join(NOTES_DIR, name)
    # O_NOFOLLOW: never follow a symlink out of the notes folder.
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as f:
        # fstat on the open file: size and mtime belong to the exact content
        # we read, even if index.php renames a new version in meanwhile.
        st = os.fstat(f.fileno())
        if not stat.S_ISREG(st.st_mode):
            raise FileNotFoundError(path)
        key = (name, st.st_mtime_ns, st.st_size)
        cached = _cache_get(key)
        if cached is not None:
            return cached
        if st.st_size > MAX_BYTES:
            raise TooLarge()
        data = f.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        raise TooLarge()
    result = count_text(data.decode("utf-8", errors="replace"))
    _cache_put(key, result)
    return result


def _reply(start_response, status, obj):
    body = json.dumps(obj).encode("utf-8")
    start_response(status, [
        ("Content-Type", "application/json"),
        ("Content-Length", str(len(body))),
        ("Cache-Control", "no-store"),
    ])
    return [body]


def application(environ, start_response):
    if environ.get("REQUEST_METHOD") not in ("GET", "HEAD"):
        return _reply(start_response, "405 Method Not Allowed", {"error": "GET only"})

    path = environ.get("PATH_INFO", "")

    if path == "/health":
        return _reply(start_response, "200 OK", {"ok": True})

    if path.startswith("/count/"):
        name = path[len("/count/"):]
        if not NAME_RE.fullmatch(name):
            return _reply(start_response, "400 Bad Request", {"error": "bad note name"})
        try:
            return _reply(start_response, "200 OK", count_note(name))
        except (FileNotFoundError, IsADirectoryError, NotADirectoryError):
            return _reply(start_response, "404 Not Found", {"error": "no such note"})
        except OSError as e:
            # ELOOP from O_NOFOLLOW lands here: treat a symlink as missing.
            if e.errno == errno.ELOOP:
                return _reply(start_response, "404 Not Found", {"error": "no such note"})
            raise
        except TooLarge:
            return _reply(start_response, "413 Payload Too Large",
                          {"error": "note larger than %d bytes" % MAX_BYTES})

    return _reply(start_response, "404 Not Found", {"error": "unknown path"})
