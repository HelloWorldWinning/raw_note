FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    TOKENIZERS_PARALLELISM=false \
    TIKTOKEN_CACHE_DIR=/opt/vocab/tiktoken \
    CLAUDE_TOKENIZER=/opt/vocab/claude-tokenizer.json \
    O_ENCODING=o200k_base \
    NOTES_DIR=/notes

WORKDIR /app

COPY requirements.txt ./
RUN pip install -r requirements.txt

# Bake all vocab files into the image (the only step that uses the network).
COPY build_vocab.py ./
RUN python build_vocab.py && rm build_vocab.py

COPY app.py ./

# Fail the build now if the service cannot start from the baked files.
RUN python -c "import app; r = app.count_text('hello world'); assert r['o'] > 0 and r['anthropic'] > 0, r; print('self-test', r)"

# www-data (uid 33) is the same user that writes the notes in the PHP container.
USER www-data

EXPOSE 6969

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:6969/health', timeout=3)"]

CMD ["gunicorn", "app:application", \
     "--bind", "0.0.0.0:6969", \
     "--preload", \
     "--workers", "2", \
     "--worker-class", "gthread", \
     "--threads", "2", \
     "--timeout", "60", \
     "--graceful-timeout", "10", \
     "--max-requests", "1000", \
     "--max-requests-jitter", "100", \
     "--worker-tmp-dir", "/dev/shm", \
     "--no-control-socket"]
