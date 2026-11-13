# raw_note

Self-hosted [Minimalist Web Notepad](https://github.com/pereorga/minimalist-web-notepad)
with search, a note list and a token-count badge (o200k_base + legacy Claude
tokenizer), in Docker.

| Notepad | Default URL          | Login            | Notes folder              |
|---------|----------------------|------------------|---------------------------|
| public  | `http://<ip>:5555`   | none             | `/data/raw_note_d`        |
| private | `http://<ip>:7777`   | `a` / `a`        | `/data/raw_note_d_passwd` |

A third container, `tokenizer`, counts tokens of saved notes. It has no
published port and no internet access.

## Install (as root)

```bash
curl -Ls4 https://raw.githubusercontent.com/HelloWorldWinning/raw_note/main/install_manger.sh | bash -s -- --install
```

Installs Docker if missing, puts the code in `/opt/raw_note`, writes settings
to `/opt/raw_note/.env`, builds and starts everything, then tests both
notepads and the token counter. Running it again repairs or updates the
install and keeps your settings.

Change the default `a` / `a` login right after installing:

```bash
raw_note --passwd USER PASS
```

## Manage

```bash
raw_note            # interactive menu (installed as /usr/local/bin/raw_note)
raw_note --help     # all commands: status, start, stop, restart, logs, update,
                    # passwd, ports, bind, tz, data, backup, uninstall
```

Without an install, run the menu straight from GitHub:

```bash
bash <(curl -Ls4 https://raw.githubusercontent.com/HelloWorldWinning/raw_note/main/install_manger.sh)
```

## Command line use

```bash
curl http://<ip>:5555/mynote                         # print a note
curl -u USER:PASS http://<ip>:7777/mynote            # private note
curl --data-binary @file.txt http://<ip>:5555/mynote # save a note
```
