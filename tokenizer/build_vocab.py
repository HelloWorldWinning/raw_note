"""Build-time only: put every vocab file the service needs into /opt/vocab,
so the running container never downloads anything.

1. o200k_base for tiktoken -> TIKTOKEN_CACHE_DIR (tiktoken checks its hash).
2. The legacy Claude tokenizer.json, taken from the anthropic 0.38.0 wheel
   (the last SDK release that shipped it) and checked against a fixed SHA-256.
"""

import glob
import hashlib
import os
import subprocess
import sys
import tempfile
import zipfile

CLAUDE_OUT = os.environ["CLAUDE_TOKENIZER"]
CLAUDE_SHA256 = "c241737df24b4e7f7c9af4fdcee29a0ca903dcb288a8b753bc346a3092911767"
O_ENCODING = os.environ.get("O_ENCODING", "o200k_base")

os.makedirs(os.environ["TIKTOKEN_CACHE_DIR"], exist_ok=True)
os.makedirs(os.path.dirname(CLAUDE_OUT), exist_ok=True)

# 1. tiktoken
import tiktoken  # noqa: E402

tiktoken.get_encoding(O_ENCODING)
print("tiktoken %s cached in %s" % (O_ENCODING, os.environ["TIKTOKEN_CACHE_DIR"]))

# 2. Claude tokenizer.json
with tempfile.TemporaryDirectory() as tmp:
    subprocess.run(
        [sys.executable, "-m", "pip", "download", "--no-deps", "--quiet",
         "--dest", tmp, "anthropic==0.38.0"],
        check=True,
    )
    wheel = glob.glob(os.path.join(tmp, "anthropic-0.38.0-*.whl"))[0]
    data = zipfile.ZipFile(wheel).read("anthropic/tokenizer.json")

digest = hashlib.sha256(data).hexdigest()
if digest != CLAUDE_SHA256:
    sys.exit("tokenizer.json SHA-256 mismatch: got %s" % digest)
with open(CLAUDE_OUT, "wb") as f:
    f.write(data)
print("Claude tokenizer.json written to %s" % CLAUDE_OUT)
