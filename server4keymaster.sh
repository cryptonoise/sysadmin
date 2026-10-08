#!/usr/bin/env bash
#
# server4keymaster.sh — автонастройка Ubuntu-сервера под KeyMaster.py
#
# Что делает:
#   • проверяет сервер (учитывает, что 3x-ui / nginx / certbot уже могут стоять)
#   • докачивает недостающие пакеты (nginx, certbot, ...)
#   • создаёт SFTP-пользователя keygen (только SFTP, без shell) и папку /var/www/keygen
#   • nginx :80  →  reload  →  сертификат Let's Encrypt (webroot)  →  nginx HTTPS
#   • ничего не ломает: чужие конфиги nginx, SSH-порт и 3x-ui не трогаются
#
# Запуск:
#   curl -fsSL https://raw.githubusercontent.com/cryptonoise/sysadmin/refs/heads/main/server4keymaster.sh | sudo bash
#
# Необязательные переменные (для запуска без вопросов):
#   curl -fsSL ... | sudo KM_DOMAIN=keygen.example.com bash
#   KM_DOMAIN, KM_YES=1
#
# Публичный ключ SFTP-пользователя всегда берётся из /root/.ssh/authorized_keys.
# Сертификат Let's Encrypt всегда выпускается без e-mail.

set -Eeuo pipefail

# ─────────────────────────── Константы ───────────────────────────
readonly SCRIPT_TITLE="KeyMaster Server Setup"
readonly SCRIPT_SUBTITLE="Автонастройка Ubuntu-сервера под KeyMaster.py"
readonly SCRIPT_VERSION="6.1"

readonly KM_USER="keygen"
readonly KM_HOME="/var/www/keygen"            # remote_folder в KeyMaster.py
readonly ACME_ROOT="/var/www/certbot"         # webroot для проверки домена
readonly SSHD_CONF="/etc/ssh/sshd_config"
readonly KEYS_DIR="/etc/ssh/keymaster"        # authorized_keys вне веб-папки
readonly KEYS_FILE="${KEYS_DIR}/${KM_USER}.keys"
readonly SSHD_BEGIN="# >>> keymaster (server4keymaster.sh) >>>"
readonly SSHD_END="# <<< keymaster (server4keymaster.sh) <<<"
readonly MARKER="/etc/keymaster-server.conf"
readonly LOG="/var/log/keymaster-setup.log"
readonly DEFAULT_SSH_PORT=1119                # server_port в KeyMaster.py
readonly TOTAL_STEPS=9

export DEBIAN_FRONTEND=noninteractive

# UTF-8 локаль: иначе кириллица считается в байтах и таблицы «едут»
_LOCALES=$(locale -a 2>/dev/null || true)
for _loc in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
    if grep -qix "$_loc" <<<"$_LOCALES"; then export LC_ALL=$_loc; break; fi
done
unset _LOCALES _loc

# ─────────────────────────── Оформление ──────────────────────────
if [[ -t 1 ]]; then
    R=$'\033[0m'; B=$'\033[1m'; DIM=$'\033[2m'
    RED=$'\033[91m'; GRN=$'\033[92m'; YEL=$'\033[93m'
    BLU=$'\033[94m'; MAG=$'\033[95m'; CYN=$'\033[96m'
    IS_TTY_OUT=1
else
    R=""; B=""; DIM=""; RED=""; GRN=""; YEL=""; BLU=""; MAG=""; CYN=""
    IS_TTY_OUT=0
fi

readonly WIDTH=64           # ширина рамок и заголовков (без учёта отступа)
readonly IN=$((WIDTH - 4))  # ширина текста внутри рамки

LOG_READY=0
log() { if (( LOG_READY )); then printf '%s\n' "$*" >>"$LOG"; fi; }

rep() {  # rep СИМВОЛ N — повторить символ N раз
    local out="" i
    for ((i = 0; i < $2; i++)); do out+=$1; done
    printf '%s' "$out"
}

pad() {  # pad "текст" ширина — дополнить пробелами по числу СИМВОЛОВ (не байтов)
    local n=$(( $2 - ${#1} ))
    printf '%s' "$1"
    if (( n > 0 )); then printf '%*s' "$n" ''; fi
}

box_open()  { printf ' %s╭%s╮%s\n' "$1" "$(rep ─ $((WIDTH - 2)))" "$R"; }
box_close() { printf ' %s╰%s╯%s\n' "$1" "$(rep ─ $((WIDTH - 2)))" "$R"; }
box_row() {  # box_row ЦВЕТ_РАМКИ "слева" "справа" [ЦВЕТ_СЛЕВА] [ЦВЕТ_СПРАВА]
    local c=$1 left=$2 right=${3:-} lc=${4:-} rc=${5:-} gap
    gap=$(( IN - ${#left} - ${#right} ))
    if (( gap < 1 )); then gap=1; fi
    printf ' %s│%s %s%s%s%s%s%s%s %s│%s\n' \
        "$c" "$R" "$lc" "$left" "$R" "$(rep ' ' "$gap")" "$rc" "$right" "$R" "$c" "$R"
}

banner() {
    echo
    box_open "$CYN"
    box_row "$CYN" "$SCRIPT_TITLE" "v${SCRIPT_VERSION}" "$GRN$B" "$DIM"
    box_row "$CYN" "$SCRIPT_SUBTITLE" "" "$DIM" ""
    box_close "$CYN"
}

heading() {  # heading "Заголовок" ["метка"]
    local text=$1 tag=${2:-} used fill
    if [[ -n $tag ]]; then
        used=$(( 4 + ${#tag} + 2 + ${#text} + 1 ))
    else
        used=$(( 4 + ${#text} + 1 ))
    fi
    fill=$(( WIDTH + 1 - used ))
    if (( fill < 3 )); then fill=3; fi
    echo
    if [[ -n $tag ]]; then
        printf ' %s━━%s %s%s%s  %s%s%s %s%s%s\n' \
            "$CYN$B" "$R" "$CYN$B" "$tag" "$R" "$B" "$text" "$R" "$DIM$CYN" "$(rep ━ "$fill")" "$R"
    else
        printf ' %s━━%s %s%s%s %s%s%s\n' \
            "$CYN$B" "$R" "$B" "$text" "$R" "$DIM$CYN" "$(rep ━ "$fill")" "$R"
    fi
    log ""
    log "=== ${tag:+[$tag] }${text} ==="
}

STEP=0
step()    { STEP=$((STEP + 1)); heading "$1" "${STEP}/${TOTAL_STEPS}"; }
section() { heading "$1"; }

ok()   { printf '  %s✔%s %s\n' "$GRN" "$R" "$*"; log "[ok]   $*"; }
info() { printf '  %s›%s %s\n' "$BLU" "$R" "$*"; log "[info] $*"; }
warn() { printf '  %s▲%s %s\n' "$YEL" "$R" "$*"; log "[warn] $*"; }
err()  { printf '  %s✖%s %s\n' "$RED" "$R" "$*" >&2; log "[err]  $*"; }
kv()   { printf '  %s%s%s %s\n' "$DIM" "$(pad "$1" 24)" "$R" "$2"; log "[info] $1: $2"; }
cfg()  {  # cfg имя значение [комментарий] — строка настроек для KeyMaster.py
    printf '    %s%s%s = %s%s%s' "$CYN" "$(pad "$1" 17)" "$R" "$GRN" "$2" "$R"
    if [[ -n ${3:-} ]]; then printf '  %s# %s%s' "$DIM" "$3" "$R"; fi
    echo
}
die()  { err "$*"; printf '  %sПодробности в логе: %s%s\n' "$DIM" "$LOG" "$R" >&2; exit 1; }

# Выполнить команду тихо (вывод в лог), показать результат одной строкой
run() {
    local desc=$1; shift
    {
        echo
        echo "### $(date '+%F %T') — $desc"
        echo "\$ $*"
    } >>"$LOG"
    if (( IS_TTY_OUT )); then printf '  %s…%s %s' "$DIM" "$R" "$desc"; fi
    if "$@" >>"$LOG" 2>&1; then
        if (( IS_TTY_OUT )); then printf '\r\033[K'; fi
        ok "$desc"
        return 0
    fi
    if (( IS_TTY_OUT )); then printf '\r\033[K'; fi
    err "$desc"
    tail -n 12 "$LOG" | sed "s/^/      ${DIM}/; s/$/${R}/" >&2
    return 1
}

trap 'err "Непредвиденная ошибка (строка $LINENO). Лог: $LOG"' ERR

# ─────────────────────────── Ввод ────────────────────────────────
# Скрипт запускается через "curl | bash", поэтому stdin занят — читаем из /dev/tty
HAVE_TTY=0
if (exec </dev/tty) 2>/dev/null; then HAVE_TTY=1; fi

prompt() {  # prompt VAR "Текст" [значение по умолчанию]
    local var=$1 text=$2 def=${3:-} ans=""
    if (( HAVE_TTY )); then
        if [[ -n $def ]]; then
            printf '  %s?%s %s %s[%s]%s: ' "$MAG" "$R" "$text" "$DIM" "$def" "$R" >/dev/tty
        else
            printf '  %s?%s %s: ' "$MAG" "$R" "$text" >/dev/tty
        fi
        IFS= read -r ans </dev/tty || ans=""
    fi
    ans=${ans:-$def}
    printf -v "$var" '%s' "$ans"
}

confirm() {  # confirm "Вопрос" Y|N  → 0 = да
    local text=$1 def=${2:-Y} ans="" hint
    if [[ $def == Y ]]; then hint="Enter/y — да, n — нет"; else hint="Enter/n — нет, y — да"; fi
    if (( ! HAVE_TTY )) || [[ ${KM_YES:-0} == 1 ]]; then
        if [[ $def == Y ]]; then return 0; else return 1; fi
    fi
    printf '  %s?%s %s %s[%s]%s: ' "$MAG" "$R" "$text" "$DIM" "$hint" "$R" >/dev/tty
    IFS= read -r ans </dev/tty || ans=""
    ans=${ans:-$def}
    case ${ans,,} in
        y|yes|д|да) return 0 ;;
        *) return 1 ;;
    esac
}

# ─────────────────────────── Хелперы ─────────────────────────────
mk_get() {  # значение из файла-метки
    if [[ -f $MARKER ]]; then
        grep -m1 "^$1=" "$MARKER" 2>/dev/null | cut -d= -f2- || true
    fi
}

port_owner() {  # имя процесса, слушающего TCP-порт (пусто — порт свободен)
    local out name
    out=$(ss -H -ltnp "sport = :$1" 2>/dev/null || true)
    if [[ -z $out ]]; then return 0; fi
    name=$(grep -o 'users:(("[^"]*"' <<<"$out" | head -n1 | sed 's/users:(("//; s/"//' || true)
    echo "${name:-unknown}"
}

get_public_ip() {
    local ip="" u
    for u in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
        ip=$(curl -4 -fsS --max-time 5 "$u" 2>/dev/null | tr -d '[:space:]' || true)
        if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "$ip"; return 0; fi
    done
    hostname -I 2>/dev/null | awk '{print $1}' || true
}

ssh_ports() {  # список портов sshd через запятую
    sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | paste -sd, - || true
}

domain_to_regex() { sed 's/[.]/\\./g' <<<"$1"; }

# ─────────────────────────── Nginx ───────────────────────────────
NGINX_VER=""
CONF_AVAIL=""
CONF_LINK=""
CONF_BACKUP=""

resolve_nginx_paths() {
    NGINX_VER=$(nginx -v 2>&1 | sed -n 's|.*nginx/\([0-9.]*\).*|\1|p' || true)
    if grep -qE 'include[[:space:]]+/etc/nginx/sites-enabled' /etc/nginx/nginx.conf 2>/dev/null; then
        mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
        CONF_AVAIL="/etc/nginx/sites-available/${DOMAIN}.conf"
        CONF_LINK="/etc/nginx/sites-enabled/${DOMAIN}.conf"
    else
        CONF_AVAIL="/etc/nginx/conf.d/${DOMAIN}.conf"
        CONF_LINK=""
    fi
}

nginx_http2_directive() {  # nginx >= 1.25.1: отдельная директива "http2 on;"
    [[ -n $NGINX_VER ]] || return 1
    [[ "$(printf '%s\n1.25.1\n' "$NGINX_VER" | sort -V | head -n1)" == "1.25.1" ]]
}

has_ipv6() {
    [[ -e /proc/net/if_inet6 ]] && [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 1)" == "0" ]]
}

write_conf_http() {
    local l6=""
    if has_ipv6; then l6="listen [::]:80;"; fi
    cat >"$CONF_AVAIL" <<EOF
# Managed by server4keymaster.sh — этап 1 (HTTP, до выпуска сертификата)
server {
    listen 80;
    ${l6}
    server_name ${DOMAIN};

    add_header X-KeyMaster "stage1-http" always;   # метка для диагностики

    location ^~ /.well-known/acme-challenge/ {
        root ${ACME_ROOT};
        default_type text/plain;
    }

    location / {
        return 404;
    }
}
EOF
}

write_conf_https() {
    local l6_80="" l6_ssl="" ssl_opts="ssl" http2_line="" redir_port=""
    if has_ipv6; then
        l6_80="listen [::]:80;"
        l6_ssl="listen [::]:${HTTPS_PORT} ssl;"
    fi
    if nginx_http2_directive; then
        http2_line="http2 on;"
    else
        ssl_opts="ssl http2"
        if has_ipv6; then l6_ssl="listen [::]:${HTTPS_PORT} ssl http2;"; fi
    fi
    if [[ $HTTPS_PORT != 443 ]]; then redir_port=":${HTTPS_PORT}"; fi

    cat >"$CONF_AVAIL" <<EOF
# Managed by server4keymaster.sh — этап 2 (HTTPS)
server {
    listen 80;
    ${l6_80}
    server_name ${DOMAIN};

    location ^~ /.well-known/acme-challenge/ {
        root ${ACME_ROOT};
        default_type text/plain;
    }

    location / {
        return 301 https://\$host${redir_port}\$request_uri;
    }
}

server {
    listen ${HTTPS_PORT} ${ssl_opts};
    ${l6_ssl}
    ${http2_line}
    server_name ${DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_session_tickets off;

    server_tokens off;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Strict-Transport-Security "max-age=63072000" always;

    charset utf-8;
    root ${KM_HOME};
    index index.html;
    autoindex off;
    client_max_body_size 100M;

    access_log /var/log/nginx/keymaster.access.log;
    error_log  /var/log/nginx/keymaster.error.log warn;

    location ~ /\\. {
        deny all;
        return 404;
    }

    location / {
        try_files \$uri =404;
    }
}
EOF
}

enable_conf() {
    if [[ -n $CONF_LINK ]]; then ln -sf "$CONF_AVAIL" "$CONF_LINK"; fi
}

rollback_conf() {  # убрать наш конфиг, чтобы не сломать остальной nginx
    if [[ -n $CONF_LINK ]]; then rm -f "$CONF_LINK"; fi
    if [[ -n $CONF_BACKUP && -f $CONF_BACKUP ]]; then
        cp -a "$CONF_BACKUP" "$CONF_AVAIL"
        enable_conf
    else
        rm -f "$CONF_AVAIL"
    fi
}

nginx_apply() {  # nginx -t → reload (если работает) или запуск
    if ! run "Проверка конфигурации (nginx -t)" nginx -t; then
        rollback_conf
        die "nginx -t не прошёл — наш конфиг откатан, остальной nginx не затронут"
    fi
    if systemctl is-active --quiet nginx; then
        run "Перезагрузка nginx (без обрыва текущих соединений)" systemctl reload nginx || die "Не удалось перезагрузить nginx"
    else
        run "Запуск nginx" systemctl enable --now nginx || die "Не удалось запустить nginx"
    fi
}

# Диагностика: почему nginx не отдал challenge-файл (пишет в лог, вердикт — в консоль)
diagnose_acme() {
    {
        echo
        echo "### $(date '+%F %T') — ДИАГНОСТИКА: nginx не отдал challenge-файл"
        echo "Запрос : GET http://127.0.0.1/.well-known/acme-challenge/${PROBE_NAME} (Host: ${DOMAIN})"
        echo "Попыток: ${PROBE_TRIES}; HTTP-код: ${PROBE_CODE:-нет ответа}; тело: '${PROBE_BODY:0:200}'"
        echo "--- заголовки ответа на пробу"
        cat "$PROBE_HDRS" 2>/dev/null || true
        echo "--- HEAD / (какой server-блок отвечает; наш помечен X-KeyMaster)"
        curl -sI --max-time 5 -H "Host: ${DOMAIN}" http://127.0.0.1/ 2>&1 || true
        echo "--- путь и права файла-пробы"
        namei -l "$PROBE_FILE" 2>&1 || true
        echo "--- наш конфиг"
        ls -l "$CONF_AVAIL" ${CONF_LINK:+"$CONF_LINK"} 2>&1 || true
        echo "--- кто слушает :80"
        ss -ltnp 'sport = :80' 2>&1 || true
        echo "--- listen / server_name во всей активной конфигурации (nginx -T)"
        nginx -T 2>/dev/null | grep -nE '^# configuration file|^[[:space:]]*(listen|server_name)[[:space:]]|default_server' || true
        echo "--- переменные прокси в окружении"
        env | grep -i proxy || echo "(нет)"
        echo "--- nginx error.log (последние 15 строк)"
        tail -n 15 /var/log/nginx/error.log 2>&1 || true
    } >>"$LOG" 2>&1

    if grep -qi '^x-keymaster:' "$PROBE_HDRS" 2>/dev/null; then
        err "Ответил наш server-блок, но файл не отдан (HTTP ${PROBE_CODE:-?}) — проверьте путь и права ${ACME_ROOT}"
    elif [[ -z $PROBE_CODE ]]; then
        err "nginx не ответил на 127.0.0.1:80 (попыток: ${PROBE_TRIES})"
    else
        err "Запрос обработал ДРУГОЙ server-блок (HTTP ${PROBE_CODE}) — он перехватывает ${DOMAIN}"
    fi
}

# ─────────────────────────── SSH / SFTP ──────────────────────────
reload_sshd() {
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || systemctl restart sshd
}

remove_sshd_block() {
    if grep -qF "$SSHD_BEGIN" "$SSHD_CONF" 2>/dev/null; then
        sed -i "\|^${SSHD_BEGIN//\//\\/}\$|,\|^${SSHD_END//\//\\/}\$|d" "$SSHD_CONF"
    fi
}

configure_sshd() {
    local backup
    backup=$(mktemp)
    cp -a "$SSHD_CONF" "$backup"
    if [[ ! -f ${SSHD_CONF}.keymaster.bak ]]; then cp -a "$SSHD_CONF" "${SSHD_CONF}.keymaster.bak"; fi

    remove_sshd_block
    if [[ -s $SSHD_CONF && -n "$(tail -c1 "$SSHD_CONF")" ]]; then echo >>"$SSHD_CONF"; fi
    cat >>"$SSHD_CONF" <<EOF
${SSHD_BEGIN}
Match User ${KM_USER}
    AuthorizedKeysFile ${KEYS_DIR}/%u.keys
    ForceCommand internal-sftp -u 022
    PasswordAuthentication no
    PubkeyAuthentication yes
    AllowTcpForwarding no
    X11Forwarding no
    PermitTTY no
${SSHD_END}
EOF
    mkdir -p /run/sshd
    if ! sshd -t >>"$LOG" 2>&1; then
        cp -a "$backup" "$SSHD_CONF"
        rm -f "$backup"
        die "sshd -t не прошёл — sshd_config восстановлен из копии"
    fi
    rm -f "$backup"
    reload_sshd || die "Не удалось перезагрузить sshd"
}

# ─────────────────────────── Файл-метка ──────────────────────────
write_marker() {
    cat >"$MARKER" <<EOF
INSTALLED_AT=$(date '+%F %T')
SCRIPT_VERSION=${SCRIPT_VERSION}
DOMAIN=${DOMAIN}
USER=${KM_USER}
HOME_DIR=${KM_HOME}
HTTPS_PORT=${HTTPS_PORT}
NGINX_CONF=${CONF_AVAIL}
NGINX_LINK=${CONF_LINK}
EOF
    chmod 644 "$MARKER"
}

# ─────────────────────────── Откат ───────────────────────────────
do_uninstall() {
    local d u conf link
    d=$(mk_get DOMAIN); u=$(mk_get USER); conf=$(mk_get NGINX_CONF); link=$(mk_get NGINX_LINK)
    u=${u:-$KM_USER}

    section "Удаление KeyMaster-настроек"
    warn "Будут удалены: конфиг nginx для ${d:-?}, SFTP-пользователь ${u}, SSH-правила, метка."
    info "nginx, certbot, 3x-ui и SSH-порт остаются как есть."
    if ! confirm "Продолжить удаление?" N; then info "Отменено."; exit 0; fi

    if [[ -n $link ]]; then rm -f "$link"; fi
    if [[ -n $conf ]]; then rm -f "$conf"; fi
    if command -v nginx >/dev/null 2>&1 && nginx -t >>"$LOG" 2>&1; then
        systemctl reload nginx >>"$LOG" 2>&1 || true
    fi
    ok "Конфиг nginx удалён"

    remove_sshd_block
    rm -f "$KEYS_FILE"
    rmdir "$KEYS_DIR" 2>/dev/null || true
    if sshd -t >>"$LOG" 2>&1; then reload_sshd || true; fi
    ok "SSH-правила удалены"

    if id "$u" >/dev/null 2>&1; then
        userdel "$u" >>"$LOG" 2>&1 || true
        ok "Пользователь ${u} удалён"
    fi

    if [[ -d $KM_HOME ]] && confirm "Удалить папку ${KM_HOME} вместе с файлами?" Y; then
        rm -rf "$KM_HOME"
        ok "Папка удалена"
    fi

    if [[ -n $d && -d /etc/letsencrypt/live/$d ]] && confirm "Удалить сертификат ${d}?" Y; then
        certbot delete --cert-name "$d" --non-interactive >>"$LOG" 2>&1 || warn "Не удалось удалить сертификат (certbot delete --cert-name $d)"
        ok "Сертификат удалён"
    fi

    rm -f "$MARKER"
    echo
    ok "Откат завершён"
    exit 0
}

# ═════════════════════════════════════════════════════════════════
#                              СТАРТ
# ═════════════════════════════════════════════════════════════════
banner

if [[ $EUID -ne 0 ]]; then
    err "Нужны права root. Запустите так: curl -fsSL <url> | sudo bash"
    exit 1
fi
mkdir -p "$(dirname "$LOG")"
touch "$LOG"; chmod 600 "$LOG"
LOG_READY=1
{
    echo
    echo "=== ${SCRIPT_TITLE} v${SCRIPT_VERSION} — $(date '+%F %T') ==="
    echo "host: $(hostname), kernel: $(uname -r), запуск от: ${SUDO_USER:-root}"
} >>"$LOG"

# ───────────────────── [1] Проверка окружения ─────────────────────
step "Проверка сервера"

[[ -r /etc/os-release ]] || die "Не удалось определить ОС"
OS_ID=$(. /etc/os-release; echo "${ID:-unknown}")
OS_NAME=$(. /etc/os-release; echo "${PRETTY_NAME:-unknown}")
command -v apt-get >/dev/null 2>&1 || die "Нужен apt (Ubuntu/Debian). Найдено: ${OS_NAME}"
if [[ $OS_ID != ubuntu && $OS_ID != debian ]]; then warn "Скрипт рассчитан на Ubuntu; у вас ${OS_NAME}"; fi
if (( ! HAVE_TTY )) && [[ -z ${KM_DOMAIN:-} ]]; then
    die "Нет терминала для ввода. Передайте параметры: sudo KM_DOMAIN=keygen.example.com bash"
fi

PUBLIC_IP=$(get_public_ip)
SSH_PORTS=$(ssh_ports)
SSH_PORT=${SSH_PORTS%%,*}
if [[ ",${SSH_PORTS}," == *",${DEFAULT_SSH_PORT},"* ]]; then SSH_PORT=$DEFAULT_SSH_PORT; fi
SSH_PORT=${SSH_PORT:-22}

kv "ОС" "$OS_NAME"
kv "Публичный IP" "${PUBLIC_IP:-не определён}"
kv "SSH-порт(ы)" "${SSH_PORTS:-не определён}"
if [[ $SSH_PORT != "$DEFAULT_SSH_PORT" ]]; then
    warn "В KeyMaster.py сейчас server_port = ${DEFAULT_SSH_PORT}, а sshd слушает ${SSH_PORT} — поправьте значение в скрипте"
fi

if command -v nginx >/dev/null 2>&1; then
    NGINX_STATE=$(systemctl is-active nginx 2>/dev/null || true)
    kv "nginx" "установлен ($(nginx -v 2>&1 | sed 's|.*/||')), ${NGINX_STATE:-unknown}"
else
    kv "nginx" "не установлен — будет установлен"
fi
if command -v certbot >/dev/null 2>&1; then
    kv "certbot" "установлен"
else
    kv "certbot" "не установлен — будет установлен"
fi

if command -v x-ui >/dev/null 2>&1 || [[ -d /usr/local/x-ui ]] || systemctl cat x-ui.service >/dev/null 2>&1; then
    XUI_STATE=$(systemctl is-active x-ui 2>/dev/null || true)
    kv "3x-ui" "обнаружена (${XUI_STATE:-unknown}) — не трогаем"
else
    kv "3x-ui" "не найдена (для KeyMaster не требуется)"
fi

UFW_ACTIVE=0
if command -v ufw >/dev/null 2>&1; then
    UFW_STATUS=$(ufw status 2>/dev/null || true)
    if grep -q '^Status: active' <<<"$UFW_STATUS"; then UFW_ACTIVE=1; fi
fi
if (( UFW_ACTIVE )); then kv "Firewall (ufw)" "активен — откроем нужные порты"; else kv "Firewall (ufw)" "не активен — правила не меняем"; fi

if (( UFW_ACTIVE )) && [[ -n ${SSH_PORTS} ]]; then
    for p in ${SSH_PORTS//,/ }; do
        if ! grep -qE "^${p}(/tcp)?[[:space:]]+ALLOW" <<<"$UFW_STATUS"; then
            warn "Порт SSH ${p} не найден в правилах ufw — проверьте доступ по SSH"
        fi
    done
fi

# Повторный запуск
if [[ -f $MARKER ]]; then
    echo
    warn "Найдена метка предыдущей установки"
    kv "Домен" "$(mk_get DOMAIN)"
    kv "Установлено" "$(mk_get INSTALLED_AT)"
    echo
    echo "    1) Обновить настройки (домен / сертификат)"
    echo "    2) Удалить всё, что создал скрипт"
    echo "    3) Выйти"
    prompt ACTION "Выбор" "1"
    case $ACTION in
        1) info "Продолжаем: настройки будут обновлены" ;;
        2) do_uninstall ;;
        *) exit 0 ;;
    esac
fi

# ───────────────────── [2] Параметры ──────────────────────────────
step "Параметры установки"

DOMAIN=""
DOMAIN_DEFAULT=$(mk_get DOMAIN)
while true; do
    if [[ -n ${KM_DOMAIN:-} ]]; then d=$KM_DOMAIN; else prompt d "Домен для KeyMaster (например keygen.example.com)" "$DOMAIN_DEFAULT"; fi
    d=$(tr 'A-Z' 'a-z' <<<"$d" | sed -E 's#^[a-z]+://##; s#[/:].*$##; s#[[:space:]]##g')
    if [[ $d =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9-]{2,}$ ]]; then DOMAIN=$d; break; fi
    if [[ -n ${KM_DOMAIN:-} ]] || (( ! HAVE_TTY )); then die "Некорректный домен: ${d}"; fi
    err "Некорректный домен, попробуйте ещё раз"
done
ok "Домен: ${DOMAIN}"

# SSH-ключ для SFTP-пользователя: всегда ключи root, без вопросов
ROOT_KEYS=""
if [[ -f /root/.ssh/authorized_keys ]]; then
    ROOT_KEYS=$(grep -E '^(ssh-|ecdsa-|sk-)' /root/.ssh/authorized_keys || true)
fi
[[ -n $ROOT_KEYS ]] || die "В /root/.ssh/authorized_keys нет ключей — SFTP-пользователю нечего выдавать"

KEY_DATA=""; KEY_OK=0; KEY_RSA=0
tmp_key=$(mktemp)
while IFS= read -r line; do
    [[ -z $line ]] && continue
    printf '%s\n' "$line" >"$tmp_key"
    if ssh-keygen -l -f "$tmp_key" >/dev/null 2>&1; then
        KEY_DATA+="${line}"$'\n'
        KEY_OK=$((KEY_OK + 1))
        if [[ $line == ssh-rsa* ]]; then KEY_RSA=$((KEY_RSA + 1)); fi
    else
        log "Пропущен некорректный ключ root: ${line:0:50}…"
    fi
done <<<"$ROOT_KEYS"
rm -f "$tmp_key"
(( KEY_OK > 0 )) || die "В /root/.ssh/authorized_keys не найдено ни одного корректного ключа"
if (( KEY_RSA == 0 )); then
    warn "Среди ключей root нет ssh-rsa, а KeyMaster.py использует paramiko.RSAKey — нужен RSA-ключ"
fi

echo
section "Проверьте параметры"
kv "Домен" "$DOMAIN"
kv "SFTP-пользователь" "$KM_USER (только SFTP, без shell)"
kv "Папка" "$KM_HOME"
kv "SSH-порт (не меняется)" "$SSH_PORT"
if ! confirm "Начать установку?" Y; then info "Отменено."; exit 0; fi

# ───────────────────── [3] DNS и порты ────────────────────────────
step "DNS и порты"

RESOLVED_IP=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1; exit}' || true)
if [[ -z $RESOLVED_IP ]]; then
    warn "Домен ${DOMAIN} пока не резолвится — сертификат не выпустится без A-записи на ${PUBLIC_IP:-IP сервера}"
    confirm "Всё равно продолжить?" N || die "Создайте A-запись ${DOMAIN} → ${PUBLIC_IP:-IP сервера} и запустите скрипт снова"
elif [[ -n $PUBLIC_IP && $RESOLVED_IP != "$PUBLIC_IP" ]]; then
    warn "${DOMAIN} → ${RESOLVED_IP}, а IP сервера ${PUBLIC_IP}"
    info "Если включён Cloudflare-прокси (оранжевое облако) — выключите его на время выпуска сертификата"
    confirm "Всё равно продолжить?" N || die "Поправьте A-запись и запустите скрипт снова"
else
    ok "DNS: ${DOMAIN} → ${RESOLVED_IP}"
fi

OWNER_80=$(port_owner 80)
if [[ -n $OWNER_80 && $OWNER_80 != nginx ]]; then
    die "Порт 80 занят процессом «${OWNER_80}». Он нужен для проверки домена Let's Encrypt — освободите его."
fi
if [[ -n $OWNER_80 ]]; then ok "Порт 80: nginx"; else ok "Порт 80: свободен"; fi

HTTPS_PORT=$(mk_get HTTPS_PORT)
HTTPS_PORT=${HTTPS_PORT:-443}
OWNER_443=$(port_owner "$HTTPS_PORT")
if [[ -n $OWNER_443 && $OWNER_443 != nginx ]]; then
    warn "Порт ${HTTPS_PORT} занят процессом «${OWNER_443}» (например, Xray/Reality из 3x-ui)"
    while true; do
        prompt HTTPS_PORT "Другой HTTPS-порт для KeyMaster" "4443"
        if [[ ! $HTTPS_PORT =~ ^[0-9]+$ ]] || (( HTTPS_PORT < 1 || HTTPS_PORT > 65535 )); then err "Некорректный порт"; continue; fi
        OWNER_ALT=$(port_owner "$HTTPS_PORT")
        if [[ -n $OWNER_ALT && $OWNER_ALT != nginx ]]; then err "Порт ${HTTPS_PORT} тоже занят (${OWNER_ALT})"; continue; fi
        break
    done
    warn "Тогда в KeyMaster.py: media_domain = \"https://${DOMAIN}:${HTTPS_PORT}\""
fi
ok "HTTPS-порт: ${HTTPS_PORT}"

# ───────────────────── [4] Пакеты ─────────────────────────────────
step "Необходимые пакеты"

NEED=()
for pkg in nginx certbot curl ca-certificates openssl openssh-server; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then NEED+=("$pkg"); fi
done
if (( ${#NEED[@]} > 0 )); then
    info "Будут установлены: ${NEED[*]}"
    run "Обновление списка пакетов" apt-get -o DPkg::Lock::Timeout=120 update -qq || die "apt-get update завершился с ошибкой"
    run "Установка пакетов" apt-get -o DPkg::Lock::Timeout=120 install -y -qq "${NEED[@]}" || die "Не удалось установить пакеты"
else
    ok "Все нужные пакеты уже установлены"
fi
command -v nginx >/dev/null 2>&1 || die "nginx не найден после установки"
resolve_nginx_paths
ok "nginx ${NGINX_VER:-?}"
run "Автозапуск nginx" systemctl enable nginx || warn "Не удалось включить автозапуск nginx"

# ───────────────────── [5] SFTP-пользователь ──────────────────────
step "SFTP-пользователь ${KM_USER}"

if id "$KM_USER" >/dev/null 2>&1; then
    ok "Пользователь ${KM_USER} уже существует"
    if [[ "$(getent passwd "$KM_USER" | cut -d: -f6)" != "$KM_HOME" ]]; then
        warn "Домашняя папка ${KM_USER} отличается от ${KM_HOME}; вход будет ограничен только SFTP"
    fi
else
    mkdir -p "$KM_HOME"
    run "Создание системного пользователя ${KM_USER}" \
        useradd -r -M -d "$KM_HOME" -s /usr/sbin/nologin "$KM_USER" || die "Не удалось создать пользователя"
fi

mkdir -p "$KM_HOME"
chown "${KM_USER}:${KM_USER}" "$KM_HOME"
chmod 755 "$KM_HOME"
ok "Папка ${KM_HOME} (владелец ${KM_USER}, чтение для nginx)"

# Ключи лежат вне веб-папки, чтобы не раздаваться nginx и не удаляться KeyMaster'ом
mkdir -p "$KEYS_DIR"
chown root:root "$KEYS_DIR"; chmod 755 "$KEYS_DIR"
printf '%s' "$KEY_DATA" >"$KEYS_FILE"
chown root:root "$KEYS_FILE"; chmod 644 "$KEYS_FILE"
log "Ключи root (${KEY_OK} шт.) записаны в ${KEYS_FILE}"

# Не мешает ли AllowUsers / AllowGroups
SSHD_EFFECTIVE=$(sshd -T 2>/dev/null || true)
ALLOW_LINE=$(grep -E '^(allowusers|allowgroups) ' <<<"$SSHD_EFFECTIVE" || true)
if [[ -n $ALLOW_LINE ]] && ! grep -qw "$KM_USER" <<<"$ALLOW_LINE"; then
    warn "В sshd_config задано ограничение: ${ALLOW_LINE}"
    warn "Добавьте ${KM_USER} в AllowUsers, иначе вход по SFTP будет запрещён"
fi

configure_sshd
ok "sshd: ${KM_USER} → только internal-sftp, вход по ключу (порт не менялся)"
write_marker

# ───────────────────── [6] Nginx :80 ──────────────────────────────
step "Nginx — конфиг для порта 80"

# Тот же домен в чужом конфиге?
DOM_RE=$(domain_to_regex "$DOMAIN")
OTHER_CONFS=$(grep -RlE "server_name[^;]*[[:space:]]${DOM_RE}([[:space:]]|;)" /etc/nginx/sites-enabled /etc/nginx/conf.d 2>/dev/null \
    | grep -v -e "/${DOMAIN}\.conf\$" || true)
if [[ -n $OTHER_CONFS ]]; then
    warn "Домен ${DOMAIN} уже упоминается в других конфигах nginx:"
    sed 's/^/      /' <<<"$OTHER_CONFS"
    confirm "Продолжить (возможен конфликт server_name)?" N || die "Остановлено: уберите дубликат домена и запустите снова"
fi

# Старый домен из прошлой установки
OLD_DOMAIN=$(mk_get DOMAIN)
OLD_CONF=$(mk_get NGINX_CONF)
OLD_LINK=$(mk_get NGINX_LINK)
if [[ -n $OLD_DOMAIN && $OLD_DOMAIN != "$DOMAIN" && -n $OLD_CONF ]]; then
    info "Домен изменён (${OLD_DOMAIN} → ${DOMAIN}) — удаляю старый конфиг nginx"
    if [[ -n $OLD_LINK ]]; then rm -f "$OLD_LINK"; fi
    rm -f "$OLD_CONF"
fi

mkdir -p "${ACME_ROOT}/.well-known/acme-challenge"
chmod -R 755 "$ACME_ROOT"

if [[ -f $CONF_AVAIL ]]; then
    CONF_BACKUP="${CONF_AVAIL}.bak.$(date +%s)"
    cp -a "$CONF_AVAIL" "$CONF_BACKUP"
    info "Существующий конфиг сохранён: ${CONF_BACKUP}"
fi
write_conf_http
enable_conf
ok "Конфиг записан: ${CONF_AVAIL}"
nginx_apply

if (( UFW_ACTIVE )); then
    run "ufw: порт 80/tcp" ufw allow 80/tcp || warn "Не удалось добавить правило ufw для 80"
    run "ufw: порт ${HTTPS_PORT}/tcp" ufw allow "${HTTPS_PORT}/tcp" || warn "Не удалось добавить правило ufw для ${HTTPS_PORT}"
else
    info "Если у хостера есть внешний firewall — откройте 80/tcp и ${HTTPS_PORT}/tcp"
fi

# Самопроверка: отдаёт ли nginx challenge-файлы.
# После reload новые воркеры стартуют не мгновенно, поэтому несколько попыток.
PROBE_NAME="km-probe-$$"
PROBE_FILE="${ACME_ROOT}/.well-known/acme-challenge/${PROBE_NAME}"
PROBE_HDRS=$(mktemp)
PROBE_BODY=""; PROBE_CODE=""; PROBE_TRIES=0
echo "km-ok" >"$PROBE_FILE"
chmod 644 "$PROBE_FILE"
for PROBE_TRIES in 1 2 3 4 5 6 7 8 9 10; do
    PROBE_BODY=$(curl -s --max-time 5 -D "$PROBE_HDRS" -H "Host: ${DOMAIN}" \
        "http://127.0.0.1/.well-known/acme-challenge/${PROBE_NAME}" || true)
    PROBE_CODE=$(awk 'NR==1{print $2}' "$PROBE_HDRS" 2>/dev/null || true)
    if [[ $PROBE_BODY == km-ok ]]; then break; fi
    sleep 0.5
done
if [[ $PROBE_BODY == km-ok ]]; then
    rm -f "$PROBE_FILE" "$PROBE_HDRS"
    ok "nginx отдаёт challenge-файлы для ${DOMAIN}"
else
    diagnose_acme
    rm -f "$PROBE_FILE" "$PROBE_HDRS"
    rollback_conf
    if nginx -t >>"$LOG" 2>&1; then systemctl reload nginx >>"$LOG" 2>&1 || true; fi
    die "nginx не отдаёт /.well-known/ для ${DOMAIN} — наш конфиг откатан, причина записана в лог"
fi

# ───────────────────── [7] Сертификат ─────────────────────────────
step "SSL-сертификат Let's Encrypt"

LIVE="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
CERT_READY=0
if [[ -f $LIVE ]] \
    && openssl x509 -checkend 2592000 -noout -in "$LIVE" >/dev/null 2>&1 \
    && openssl x509 -noout -ext subjectAltName -in "$LIVE" 2>/dev/null | grep -q "DNS:${DOMAIN}"; then
    CERT_READY=1
    ok "Действующий сертификат уже есть (срок > 30 дней) — перевыпуск не нужен"
fi

if (( ! CERT_READY )); then
    CERTBOT_ARGS=(certonly --webroot -w "$ACME_ROOT" -d "$DOMAIN" --cert-name "$DOMAIN"
        --non-interactive --agree-tos --keep-until-expiring --register-unsafely-without-email)
    if ! run "Запрос сертификата для ${DOMAIN}" certbot "${CERTBOT_ARGS[@]}"; then
        echo
        warn "Сертификат не выпущен. Частые причины:"
        echo "      • A-запись ${DOMAIN} не указывает на ${PUBLIC_IP:-этот сервер}"
        echo "      • порт 80 закрыт во внешнем firewall хостера"
        echo "      • включён Cloudflare-прокси (оранжевое облако)"
        echo "      • превышен лимит Let's Encrypt (5 неудач в час)"
        info "HTTP-конфиг оставлен рабочим. После исправления просто запустите скрипт снова."
        exit 1
    fi
    [[ -f $LIVE ]] || die "Сертификат не появился в /etc/letsencrypt/live/${DOMAIN}/"
fi

mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat >/etc/letsencrypt/renewal-hooks/deploy/keymaster-reload-nginx.sh <<'EOF'
#!/bin/bash
systemctl reload nginx
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/keymaster-reload-nginx.sh
ok "Хук автопродления: reload nginx после обновления"
if systemctl enable --now certbot.timer >>"$LOG" 2>&1; then
    ok "Автопродление включено (certbot.timer)"
else
    warn "certbot.timer не найден — проверьте автопродление вручную (certbot renew)"
fi

# ───────────────────── [8] Nginx HTTPS ────────────────────────────
step "Nginx — включение HTTPS"

CONF_BACKUP=$(mktemp)
cp -a "$CONF_AVAIL" "$CONF_BACKUP"   # HTTP-версия — на случай отката
write_conf_https
enable_conf
ok "Конфиг HTTPS записан: ${CONF_AVAIL}"
if ! nginx -t >>"$LOG" 2>&1; then
    err "nginx -t не прошёл с HTTPS-конфигом — возвращаю HTTP-версию"
    cp -a "$CONF_BACKUP" "$CONF_AVAIL"
    rm -f "$CONF_BACKUP"
    nginx -t >>"$LOG" 2>&1 && systemctl reload nginx >>"$LOG" 2>&1 || true
    die "Ошибка в HTTPS-конфиге nginx"
fi
rm -f "$CONF_BACKUP"; CONF_BACKUP=""
nginx_apply
write_marker

# ───────────────────── [9] Проверка и итоги ───────────────────────
step "Финальная проверка"

CHECK_FILE="${KM_HOME}/km-selftest-$$.txt"
echo "keymaster-ok" >"$CHECK_FILE"
chown "${KM_USER}:${KM_USER}" "$CHECK_FILE"; chmod 644 "$CHECK_FILE"

HTTPS_RESULT=$(curl -fsS --max-time 10 --resolve "${DOMAIN}:${HTTPS_PORT}:127.0.0.1" \
    "https://${DOMAIN}:${HTTPS_PORT}/$(basename "$CHECK_FILE")" 2>>"$LOG" || true)
rm -f "$CHECK_FILE"
if [[ $HTTPS_RESULT == keymaster-ok ]]; then
    ok "HTTPS работает: файл из ${KM_HOME} отдаётся с валидным сертификатом"
else
    warn "Проверка HTTPS не прошла — смотрите: nginx -t, ${LOG}, /var/log/nginx/keymaster.error.log"
fi

HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Host: ${DOMAIN}" http://127.0.0.1/ || true)
if [[ $HTTP_CODE == 301 ]]; then ok "HTTP :80 → редирект на HTTPS"; else warn "HTTP :80 вернул код ${HTTP_CODE:-?} (ожидался 301)"; fi

FC=$(sshd -T -C "user=${KM_USER},host=localhost,addr=127.0.0.1" 2>/dev/null | grep -i '^forcecommand' || true)
if [[ $FC == *internal-sftp* ]]; then ok "sshd: ${KM_USER} ограничен SFTP (${FC#forcecommand })"; else warn "Не удалось подтвердить ForceCommand для ${KM_USER}"; fi

CERT_END=$(openssl x509 -enddate -noout -in "$LIVE" 2>/dev/null | cut -d= -f2 || true)
ok "Сертификат действует до: ${CERT_END:-?}"

MEDIA_URL="https://${DOMAIN}"
if [[ $HTTPS_PORT != 443 ]]; then MEDIA_URL+=":${HTTPS_PORT}"; fi

echo
box_open "$GRN"
box_row "$GRN" "✔ Сервер готов к работе с KeyMaster.py" "" "$GRN$B" ""
box_close "$GRN"

section "Пропишите в KeyMaster.py"
cfg server_ip        "\"${PUBLIC_IP:-IP_СЕРВЕРА}\""
cfg server_port      "$SSH_PORT"
cfg username         "\"${KM_USER}\""
cfg remote_folder    "\"${KM_HOME}\""
cfg media_domain     "\"${MEDIA_URL}\""
cfg private_key_path "\"uploadkey.pem\"" "приватный RSA-ключ к ключу root"

section "Проверка вручную"
printf '    sftp -i uploadkey.pem -P %s %s@%s\n' "$SSH_PORT" "$KM_USER" "${PUBLIC_IP:-IP_СЕРВЕРА}"

section "Полезное"
kv "Логи nginx"   "tail -f /var/log/nginx/keymaster.access.log"
kv "Лог скрипта"  "$LOG"
kv "Конфиг nginx" "$CONF_AVAIL"
kv "Удаление"     "запустите скрипт снова → пункт 2"
echo
