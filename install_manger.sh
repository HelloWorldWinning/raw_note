#!/usr/bin/env bash
# install_manger.sh - install and manage raw_note
# (Minimalist Web Notepad + token badge, two notepads + tokenizer in Docker)
#
#   bash install_manger.sh --install    default install, asks nothing
#   bash install_manger.sh              interactive manager menu
#   bash install_manger.sh --help       all commands
#
# From GitHub:
#   curl -Ls4 https://raw.githubusercontent.com/HelloWorldWinning/raw_note/main/install_manger.sh | bash -s -- --install
#   bash <(curl -Ls4 https://raw.githubusercontent.com/HelloWorldWinning/raw_note/main/install_manger.sh)
#
# After install, the command "raw_note" runs this script (menu or same flags).
#
# Default setup:
#   public  notepad  http://<ip>:5555  no password    notes in /data/raw_note_d
#   private notepad  http://<ip>:7777  user a / pass a notes in /data/raw_note_d_passwd
# Settings live in /opt/raw_note/.env (mode 600). Override the install folder
# with RAW_NOTE_DIR=/some/dir.

set -Eeuo pipefail

REPO_URL="${RAW_NOTE_REPO:-https://github.com/HelloWorldWinning/raw_note.git}"
BRANCH="${RAW_NOTE_BRANCH:-main}"
APP_DIR="${RAW_NOTE_DIR:-/opt/raw_note}"
ENV_FILE="$APP_DIR/.env"
CMD_LINK=/usr/local/bin/raw_note
PROJECT=raw_note                          # docker compose project name
OLD_DATA_DIR=/data/Minimalist_Web_Notepad # notes of the old single-notepad setup
BACKUP_DIR_DEFAULT=/data/raw_note_backup

# Settings stored in .env, with their defaults.
ENV_KEYS=(PUBLIC_PORT PUBLIC_DIR PRIVATE_PORT PRIVATE_DIR PRIVATE_USER PRIVATE_PASS BIND_IP TZ)
# shellcheck disable=SC2034  # read indirectly as ${!d} in load_env
declare \
    D_PUBLIC_PORT=5555 \
    D_PUBLIC_DIR=/data/raw_note_d \
    D_PRIVATE_PORT=7777 \
    D_PRIVATE_DIR=/data/raw_note_d_passwd \
    D_PRIVATE_USER=a \
    D_PRIVATE_PASS=a \
    D_BIND_IP=0.0.0.0 \
    D_TZ=Australia/Perth

# ---------------------------------------------------------------- output ----
if [ -t 1 ]; then
    C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[1m'; C_N=$'\e[0m'
else
    C_R=''; C_G=''; C_Y=''; C_B=''; C_N=''
fi
info() { printf '%s==>%s %s\n' "$C_G" "$C_N" "$*"; }
warn() { printf '%sWARN:%s %s\n' "$C_Y" "$C_N" "$*" >&2; }
die()  { printf '%sERROR:%s %s\n' "$C_R" "$C_N" "$*" >&2; exit 1; }

# --------------------------------------------------------------- helpers ----
need_root() {
    [ "$(id -u)" -eq 0 ] || die "Run as root, for example: sudo bash install_manger.sh $*"
}

is_installed() { [ -f "$APP_DIR/docker-compose.yml" ] && [ -f "$ENV_FILE" ]; }

need_installed() {
    is_installed || die "raw_note is not installed in $APP_DIR. Run: bash install_manger.sh --install"
}

dc() {
    docker compose --project-name "$PROJECT" --project-directory "$APP_DIR" \
        -f "$APP_DIR/docker-compose.yml" --env-file "$ENV_FILE" "$@"
}

# Read .env into shell variables. Missing keys get the defaults.
# Parsed line by line (not sourced), so file content is never executed.
load_env() {
    local k line v
    for k in "${ENV_KEYS[@]}"; do
        local d="D_$k"
        printf -v "$k" '%s' "${!d}"
    done
    [ -f "$ENV_FILE" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        k=${line%%=*}
        v=${line#*=}
        v=${v#\'}; v=${v%\'}
        case " ${ENV_KEYS[*]} " in *" $k "*) printf -v "$k" '%s' "$v" ;; esac
    done < "$ENV_FILE"
}

# Write all settings to .env. Values are single-quoted: docker compose then
# takes them literally (no $ expansion). valid_* below forbid "'" in values.
save_env() {
    local tmp="$ENV_FILE.tmp.$$" k
    (
        umask 077
        {
            echo "# raw_note settings, written by install_manger.sh."
            echo "# Change them with the manager (command: raw_note), not by hand."
            for k in "${ENV_KEYS[@]}"; do printf "%s='%s'\n" "$k" "${!k}"; done
        } > "$tmp"
    )
    mv -f "$tmp" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
}

valid_port() { [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && [ "$1" -le 65535 ]; }
valid_user() { [[ $1 =~ ^[A-Za-z0-9._-]{1,32}$ ]]; }
valid_pass() { [ -n "$1" ] && [ "${#1}" -le 128 ] && [[ $1 != *"'"* && $1 != *$'\n'* ]]; }
valid_ip()   { [[ $1 =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] &&
               local o && for o in "${BASH_REMATCH[@]:1}"; do [ "$o" -le 255 ] || return 1; done; }
valid_dir()  { [[ $1 == /?* && $1 != *[[:space:]\'\$\`\"\\]* && $1 != */ ]]; }
valid_tz()   { [[ $1 =~ ^[A-Za-z_]+(/[A-Za-z0-9_+-]+)*$ ]] &&
               { [ ! -d /usr/share/zoneinfo ] || [ -f "/usr/share/zoneinfo/$1" ]; }; }

PASS_RULE="1-128 characters, no single quote (') and no newline"
USER_RULE="1-32 characters from A-Z a-z 0-9 . _ -"
DIR_RULE="an absolute path, no spaces, quotes, \$, \` or backslash, no trailing /"

# Is the TCP port held by something other than raw_note's own containers?
port_busy() {
    local p=$1
    command -v ss >/dev/null 2>&1 || return 1
    ss -Htln "sport = :$p" 2>/dev/null | grep -q . || return 1
    if docker ps --filter "label=com.docker.compose.project=$PROJECT" \
            --format '{{.Ports}}' 2>/dev/null | grep -Eq ":$p->"; then
        return 1
    fi
    return 0
}

check_ports_free() {
    local p
    for p in "$@"; do
        if port_busy "$p"; then
            die "Port $p is already in use:
$(ss -Htlnp "sport = :$p" 2>/dev/null | head -3)
Stop that program, or choose another port (raw_note -> Change ports)."
        fi
    done
}

host_for_check() { if [ "$BIND_IP" = 0.0.0.0 ]; then echo 127.0.0.1; else echo "$BIND_IP"; fi; }

host_for_user() {
    if [ "$BIND_IP" != 0.0.0.0 ]; then echo "$BIND_IP"; return; fi
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo "${ip:-<server-ip>}"
}

note_count() { find "$1" -maxdepth 1 -type f ! -name '.*' 2>/dev/null | wc -l | tr -d ' '; }

ask() {   # ask "Question" [default]  -> answer in REPLY
    local q=$1 def=${2-}
    read -r -p "$q${def:+ [$def]}: " REPLY || exit 1
    REPLY=${REPLY:-$def}
}

confirm() { local a; read -r -p "$1 [y/N]: " a || exit 1; [[ $a =~ ^[Yy]$|^[Yy][Ee][Ss]$ ]]; }

pause() { read -r -p "Press Enter to return to the menu..." _ || true; }

# Run a command in a subshell so its "die" returns to the menu instead of
# quitting. "( cmd ) || true" would switch off set -e inside cmd, so set -e
# is turned on inside the subshell while the caller has it off.
run_sub() {
    set +e
    ( set -e; "$@" )
    set -e
}

# --------------------------------------------------------- install steps ----
ensure_pkgs() {
    local missing=() c
    for c in git curl; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
    [ "${#missing[@]}" -eq 0 ] && return 0
    info "Installing ${missing[*]} ..."
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${missing[@]}"
    elif command -v dnf >/dev/null 2>&1; then dnf install -y "${missing[@]}"
    elif command -v yum >/dev/null 2>&1; then yum install -y "${missing[@]}"
    elif command -v apk >/dev/null 2>&1; then apk add --no-cache "${missing[@]}"
    else die "Please install: ${missing[*]}"
    fi
}

ensure_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        info "Installing Docker (https://get.docker.com) ..."
        curl -fsSL https://get.docker.com | sh
    fi
    systemctl enable --now docker >/dev/null 2>&1 || true
    docker info >/dev/null 2>&1 || die "Docker is installed but the daemon is not running."
    docker compose version >/dev/null 2>&1 ||
        die "The 'docker compose' plugin is missing. Install the docker-compose-plugin package and retry."
}

sync_repo() {
    if [ -d "$APP_DIR/.git" ]; then
        info "Updating code in $APP_DIR ..."
        git -C "$APP_DIR" fetch -q origin "$BRANCH"
        git -C "$APP_DIR" checkout -q "$BRANCH"
        git -C "$APP_DIR" merge -q --ff-only "origin/$BRANCH" ||
            die "Local edits in $APP_DIR block the update. See: git -C $APP_DIR status"
    elif [ -e "$APP_DIR" ] && [ -n "$(ls -A "$APP_DIR" 2>/dev/null)" ]; then
        die "$APP_DIR exists, is not empty and is not a git checkout. Move it away or set RAW_NOTE_DIR."
    else
        info "Downloading code to $APP_DIR ..."
        mkdir -p "$(dirname "$APP_DIR")"
        git clone -q -b "$BRANCH" "$REPO_URL" "$APP_DIR"
    fi
    chmod +x "$APP_DIR/install_manger.sh"
    ln -sfn "$APP_DIR/install_manger.sh" "$CMD_LINK"
}

prepare_dirs() {
    mkdir -p "$PUBLIC_DIR" "$PRIVATE_DIR"
    chmod 700 "$PRIVATE_DIR"
    # One time only: copy the old setup's notes into the empty public folder.
    if [ -d "$OLD_DATA_DIR" ] && [ "$(note_count "$PUBLIC_DIR")" = 0 ] &&
       [ "$(note_count "$OLD_DATA_DIR")" != 0 ]; then
        info "Copying $(note_count "$OLD_DATA_DIR") old notes: $OLD_DATA_DIR -> $PUBLIC_DIR (old folder is kept)"
        cp -a "$OLD_DATA_DIR/." "$PUBLIC_DIR/"
    fi
}

start_stack() {   # build images, then (re)create all containers
    info "Building images. The first build downloads tokenizer files and takes a few minutes ..."
    dc build
    if ! dc up -d --remove-orphans; then
        warn "Start failed; removing old containers and trying once more ..."
        dc down --remove-orphans || true
        dc up -d
    fi
}

# Wait until both notepads answer and the tokenizer counts a real note.
health_check() {
    local h code_pub=000 code_priv=000 tok="" name
    h=$(host_for_check)
    for _ in $(seq 1 60); do
        code_pub=$(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://$h:$PUBLIC_PORT/" || true)
        code_priv=$(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://$h:$PRIVATE_PORT/" || true)
        [ "$code_pub" = 302 ] && [ "$code_priv" = 401 ] && break
        sleep 2
    done
    if [ "$code_pub" = 302 ]; then info "Public notepad  OK (port $PUBLIC_PORT)"
    else warn "Public notepad did not answer as expected (HTTP $code_pub). See: raw_note --logs"; fi
    if [ "$code_priv" = 401 ]; then info "Private notepad OK (port $PRIVATE_PORT, password required)"
    else warn "Private notepad did not answer as expected (HTTP $code_priv, wanted 401). See: raw_note --logs"; fi

    # Token counter end to end: save a scratch note, count it, delete it.
    [ "$code_pub" = 302 ] || return 0
    name="zz-raw-note-selftest-$$"
    curl -s -o /dev/null -m 5 -X POST -H 'Content-Type: text/plain' \
        --data-binary 'hello world' "http://$h:$PUBLIC_PORT/$name" || true
    for _ in $(seq 1 45); do   # tokenizer may still be loading its vocab
        tok=$(curl -s -m 35 "http://$h:$PUBLIC_PORT/$name?tokens=1" || true)
        [[ $tok == *'"anthropic"'* ]] && break
        sleep 2
    done
    curl -s -o /dev/null -m 5 -X POST -H 'Content-Type: text/plain' \
        --data-binary '' "http://$h:$PUBLIC_PORT/$name" || true
    if [[ $tok == *'"anthropic"'* ]]; then
        info "Token counter   OK ('hello world' -> $tok)"
    else
        warn "Token counter is not answering yet: ${tok:-no reply}. See: raw_note --logs"
    fi
}

summary() {
    local ip
    ip=$(host_for_user)
    echo
    echo "${C_B}raw_note${C_N}  (code: $APP_DIR, settings: $ENV_FILE)"
    printf '  Public   http://%s:%s   no password            notes: %s (%s)\n' \
        "$ip" "$PUBLIC_PORT" "$PUBLIC_DIR" "$(note_count "$PUBLIC_DIR")"
    printf '  Private  http://%s:%s   user: %s  pass: %s chars  notes: %s (%s)\n' \
        "$ip" "$PRIVATE_PORT" "$PRIVATE_USER" "${#PRIVATE_PASS}" "$PRIVATE_DIR" "$(note_count "$PRIVATE_DIR")"
    printf '  Listen IP %s   Time zone %s\n' "$BIND_IP" "$TZ"
    if [ "$PRIVATE_USER" = a ] && [ "$PRIVATE_PASS" = a ]; then
        warn "The private notepad uses the default login a / a. Change it: raw_note --passwd USER PASS"
    fi
    echo "  Manage: raw_note    (or: raw_note --help)"
}

# -------------------------------------------------------------- commands ----
cmd_install() {
    need_root --install
    ensure_pkgs
    ensure_docker
    sync_repo
    load_env      # keeps the settings of an earlier install
    save_env
    prepare_dirs
    check_ports_free "$PUBLIC_PORT" "$PRIVATE_PORT"
    start_stack
    health_check
    summary
}

cmd_status() {
    need_installed; load_env
    summary
    echo
    dc ps --format 'table {{.Service}}\t{{.State}}\t{{.Status}}\t{{.Ports}}' || true
}

cmd_start()   { need_root; need_installed; load_env; check_ports_free "$PUBLIC_PORT" "$PRIVATE_PORT"; dc up -d; health_check; }
cmd_stop()    { need_root; need_installed; dc stop; info "Stopped."; }
cmd_restart() { need_root; need_installed; load_env; dc restart; health_check; }
cmd_logs()    { need_installed; dc logs -f --tail 100; }

cmd_update() {
    need_root; need_installed
    sync_repo
    load_env; save_env
    start_stack
    health_check
    summary
}

cmd_passwd() {   # USER PASS
    need_root; need_installed
    valid_user "$1" || die "Username must be $USER_RULE."
    valid_pass "$2" || die "Password must be $PASS_RULE."
    load_env
    PRIVATE_USER=$1; PRIVATE_PASS=$2
    save_env
    dc up -d notepad-private
    info "Private notepad login is now user '$PRIVATE_USER' (password ${#PRIVATE_PASS} chars)."
}

cmd_ports() {    # PUBLIC PRIVATE
    need_root; need_installed
    valid_port "$1" && valid_port "$2" || die "Ports must be numbers from 1 to 65535."
    [ "$1" != "$2" ] || die "The two ports must differ."
    load_env
    local p
    for p in "$1" "$2"; do
        if [ "$p" != "$PUBLIC_PORT" ] && [ "$p" != "$PRIVATE_PORT" ]; then check_ports_free "$p"; fi
    done
    PUBLIC_PORT=$1; PRIVATE_PORT=$2
    save_env
    dc stop notepad notepad-private
    dc up -d
    health_check
    summary
}

cmd_bind() {     # IP
    need_root; need_installed
    valid_ip "$1" || die "Listen IP must be an IPv4 address, e.g. 0.0.0.0 (all) or 127.0.0.1 (local only)."
    load_env
    BIND_IP=$1
    save_env
    dc stop notepad notepad-private
    dc up -d
    health_check
}

cmd_tz() {       # ZONE
    need_root; need_installed
    valid_tz "$1" || die "Unknown time zone '$1'. Example: Australia/Perth, Asia/Shanghai, UTC."
    load_env
    TZ=$1
    save_env
    dc up -d notepad notepad-private
    info "Time zone is now $TZ (used for new note names and list dates)."
}

# Move every entry of folder $1 into folder $2; never overwrite.
move_entries() {
    local f left=0
    for f in "$1"/* "$1"/.[!.]* "$1"/..?*; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        if [ -e "$2/$(basename "$f")" ]; then left=$((left + 1)); continue; fi
        mv "$f" "$2/"
    done
    [ "$left" -eq 0 ] || warn "$left item(s) left in $1: same name already in $2."
}

# Copy folder $1 into folder $2; never overwrite. coreutils >= 9.3 warns
# about -n and wants --update=none; older cp only knows -n.
copy_no_clobber() {
    if cp --help 2>&1 | grep -q -- '--update\[='; then
        cp -a --update=none "$1/." "$2/"
    else
        cp -an "$1/." "$2/"
    fi
}

cmd_data() {     # PUBLIC_DIR PRIVATE_DIR MODE(move|copy|none)
    need_root; need_installed
    local np=$1 nq=$2 mode=${3:-move} old new
    valid_dir "$np" && valid_dir "$nq" || die "Folders must be $DIR_RULE."
    [ "$np" != "$nq" ] || die "The two folders must differ."
    case "$np/" in "$nq/"*) die "One folder must not be inside the other." ;; esac
    case "$nq/" in "$np/"*) die "One folder must not be inside the other." ;; esac
    case "$mode" in move|copy|none) ;; *) die "Mode must be move, copy or none." ;; esac
    load_env
    [ "$np" != "$PRIVATE_DIR" ] && [ "$nq" != "$PUBLIC_DIR" ] ||
        die "Swapping the public and private folders is not supported (notes would mix)."
    for old in "$PUBLIC_DIR" "$PRIVATE_DIR"; do
        for new in "$np" "$nq"; do
            [ "$old" = "$new" ] && continue
            case "$new/" in "$old/"*) die "$new is inside the current folder $old." ;; esac
            case "$old/" in "$new/"*) die "The current folder $old is inside $new." ;; esac
        done
    done

    info "Stopping raw_note ..."
    dc stop
    mkdir -p "$np" "$nq"
    chmod 700 "$nq"
    while read -r old new; do
        [ "$old" = "$new" ] && continue
        [ -d "$old" ] || continue
        case "$mode" in
            move) info "Moving notes $old -> $new";  move_entries "$old" "$new"
                  rmdir "$old" 2>/dev/null || true ;;
            copy) info "Copying notes $old -> $new"; copy_no_clobber "$old" "$new" ;;
            none) info "Not touching $old (notes stay there)" ;;
        esac
    done <<EOF
$PUBLIC_DIR $np
$PRIVATE_DIR $nq
EOF
    PUBLIC_DIR=$np; PRIVATE_DIR=$nq
    save_env
    dc up -d
    health_check
    summary
}

cmd_backup() {   # [DIR]
    need_root; need_installed; load_env
    local dest=${1:-$BACKUP_DIR_DEFAULT} f
    mkdir -p "$dest"
    f="$dest/raw_note_$(date +%Y-%m-%d_%H%M%S).tar.gz"
    tar -czf "$f" -C / "${PUBLIC_DIR#/}" "${PRIVATE_DIR#/}"
    chmod 600 "$f"
    info "Backup written: $f ($(du -h "$f" | cut -f1))"
    echo "  Restore: tar -xzf $f -C /"
}

cmd_uninstall() {  # [--yes]
    need_root; need_installed; load_env
    if [ "${1:-}" != --yes ]; then
        echo "This removes the containers, images, $APP_DIR and $CMD_LINK."
        echo "Notes are KEPT in $PUBLIC_DIR and $PRIVATE_DIR."
        local a; read -r -p "Type 'yes' to uninstall: " a || exit 1
        [ "$a" = yes ] || { info "Cancelled."; return 0; }
    fi
    dc down --rmi local --remove-orphans || true
    rm -f "$CMD_LINK"
    rm -rf "$APP_DIR"
    info "Uninstalled. Notes kept in $PUBLIC_DIR and $PRIVATE_DIR."
}

usage() {
    cat <<EOF
raw_note manager. Run as root.

  bash install_manger.sh --install         install with defaults, ask nothing
                                           (run again to repair; keeps settings)
  bash install_manger.sh                   interactive menu

  --status                                 URLs, folders, container state
  --start | --stop | --restart
  --logs                                   follow container logs (Ctrl-C quits)
  --update                                 git pull + rebuild + restart
  --passwd USER PASS                       private notepad login
  --ports PUBLIC PRIVATE                   e.g. --ports 5555 7777
  --bind IP                                listen IP: 0.0.0.0 = all, 127.0.0.1 = local only
  --tz ZONE                                e.g. --tz Australia/Perth
  --data PUBLIC_DIR PRIVATE_DIR [MODE]     change note folders; MODE: move (default),
                                           copy, or none (leave old notes in place)
  --backup [DIR]                           .tar.gz of both note folders
                                           (default DIR: $BACKUP_DIR_DEFAULT)
  --uninstall [--yes]                      remove app; notes are kept
  --help

From GitHub (note "bash -s --": plain "| bash --install" does not work):
  curl -Ls4 https://raw.githubusercontent.com/HelloWorldWinning/raw_note/main/install_manger.sh | bash -s -- --install
  bash <(curl -Ls4 https://raw.githubusercontent.com/HelloWorldWinning/raw_note/main/install_manger.sh)
EOF
}

# ------------------------------------------------------------------ menu ----
menu_passwd() {
    load_env
    ask "New username ($USER_RULE)" "$PRIVATE_USER"; local u=$REPLY p1 p2
    read -r -s -p "New password ($PASS_RULE): " p1; echo
    read -r -s -p "Repeat password: " p2; echo
    [ "$p1" = "$p2" ] || { warn "Passwords differ. Nothing changed."; return; }
    run_sub cmd_passwd "$u" "$p1"
}

menu_ports() {
    load_env
    ask "Public port" "$PUBLIC_PORT";   local a=$REPLY
    ask "Private port" "$PRIVATE_PORT"; local b=$REPLY
    run_sub cmd_ports "$a" "$b"
}

menu_data() {
    load_env
    ask "Public notes folder" "$PUBLIC_DIR";   local a=$REPLY
    ask "Private notes folder" "$PRIVATE_DIR"; local b=$REPLY
    if [ "$a" = "$PUBLIC_DIR" ] && [ "$b" = "$PRIVATE_DIR" ]; then info "Nothing changed."; return; fi
    echo "Existing notes:  1) move to the new folder   2) copy   3) leave them where they are"
    ask "Choose" 1
    local m
    case "$REPLY" in 1) m=move ;; 2) m=copy ;; 3) m=none ;; *) warn "Invalid choice."; return ;; esac
    run_sub cmd_data "$a" "$b" "$m"
}

menu_bind() { load_env; ask "Listen IP (0.0.0.0 = all, 127.0.0.1 = local only)" "$BIND_IP"; run_sub cmd_bind "$REPLY"; }
menu_tz()   { load_env; ask "Time zone" "$TZ"; run_sub cmd_tz "$REPLY"; }
menu_backup() { ask "Backup folder" "$BACKUP_DIR_DEFAULT"; run_sub cmd_backup "$REPLY"; }

menu() {
    need_root
    if ! is_installed; then
        echo "raw_note is not installed in $APP_DIR."
        if confirm "Install now with defaults?"; then cmd_install; else return 0; fi
        pause
    fi
    while true; do
        clear 2>/dev/null || true
        load_env
        echo "${C_B}raw_note manager${C_N}   $APP_DIR"
        echo "  public :$PUBLIC_PORT -> $PUBLIC_DIR"
        echo "  private:$PRIVATE_PORT -> $PRIVATE_DIR  (user $PRIVATE_USER)"
        echo
        echo "   1) Status              2) Start             3) Stop"
        echo "   4) Restart             5) Logs (Ctrl-C)     6) Update (git pull + rebuild)"
        echo "   7) Private login       8) Ports             9) Note folders"
        echo "  10) Listen IP          11) Time zone        12) Backup notes"
        echo "  13) Uninstall           0) Exit"
        echo
        ask "Choose"
        case "$REPLY" in
            1)  run_sub cmd_status ;;
            2)  run_sub cmd_start ;;
            3)  run_sub cmd_stop ;;
            4)  run_sub cmd_restart ;;
            5)  run_sub cmd_logs ;;
            6)  run_sub cmd_update ;;
            7)  menu_passwd ;;
            8)  menu_ports ;;
            9)  menu_data ;;
            10) menu_bind ;;
            11) menu_tz ;;
            12) menu_backup ;;
            13) run_sub cmd_uninstall; is_installed || exit 0 ;;
            0|q|Q) exit 0 ;;
            *)  warn "Unknown choice: $REPLY" ;;
        esac
        pause
    done
}

# ------------------------------------------------------------------ main ----
main() {
    if [ $# -eq 0 ]; then
        [ -t 0 ] || { usage; echo; die "The menu needs a terminal. Use: bash <(curl -Ls4 URL)  or  raw_note"; }
        menu
        return
    fi
    # Non-interactive command: when this script comes through a pipe
    # (curl | bash), stop child programs from reading the rest of the pipe.
    [ -t 0 ] || exec </dev/null
    case "$1" in
        --install)   cmd_install ;;
        --status)    cmd_status ;;
        --start)     cmd_start ;;
        --stop)      cmd_stop ;;
        --restart)   cmd_restart ;;
        --logs)      cmd_logs ;;
        --update)    cmd_update ;;
        --passwd)    [ $# -eq 3 ] || die "Usage: --passwd USER PASS"; cmd_passwd "$2" "$3" ;;
        --ports)     [ $# -eq 3 ] || die "Usage: --ports PUBLIC PRIVATE"; cmd_ports "$2" "$3" ;;
        --bind)      [ $# -eq 2 ] || die "Usage: --bind IP"; cmd_bind "$2" ;;
        --tz)        [ $# -eq 2 ] || die "Usage: --tz ZONE"; cmd_tz "$2" ;;
        --data)      [ $# -ge 3 ] && [ $# -le 4 ] || die "Usage: --data PUBLIC_DIR PRIVATE_DIR [move|copy|none]"
                     cmd_data "$2" "$3" "${4:-move}" ;;
        --backup)    cmd_backup "${2:-}" ;;
        --uninstall) cmd_uninstall "${2:-}" ;;
        -h|--help|help) usage ;;
        *)           usage; echo; die "Unknown option: $1" ;;
    esac
}

main "$@"
exit $?
