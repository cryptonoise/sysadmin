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
#   curl -fsSL ... | sudo KM_DOMAIN=keygen.example.com KM_EMAIL=me@example.com bash
#   KM_DOMAIN, KM_EMAIL, KM_PUBKEY ("ssh-rsa AAAA..."), KM_YES=1

set -Eeuo pipefail

# ─────────────────────────── Константы ───────────────────────────
readonly SCRIPT_TITLE="KeyMaster · Server Setup"
readonly SCRIPT_VERSION="6.0"

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

# ─────────────────────────── Оформление ──────────────────────────
if [[ -t 1 ]]; then
    R=$'\033[0m'; B=$'\033[1m'; DIM=$'\033[2m'
    RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'
    BLU=$'\033[34m'; MAG=$'\033[35m'; CYN=$'\033[36m'
    IS_TTY_OUT=1
else
    R=""; B=""; DIM=""; RED=""; GRN=""; YEL=""; BLU=""; MAG=""; CYN=""
    IS_TTY_OUT=0
fi

HR=""
for ((i = 0; i < 60; i++)); do HR+="━"; done

STEP=0
step() {
    STEP=$((STEP + 1))
    echo
    printf '%s%s[%d/%d]%s %s%s%s\n' "$CYN" "$B" "$STEP" "$TOTAL_STEPS" "$R" "$B" "$1" "$R"
    printf '%s%s%s\n' "$DIM" "$HR" "$R"
}
section() {
    echo
    printf '%s%s%s%s\n' "$CYN" "$B" "$1" "$R"
    printf '%s%s%s\n' "$DIM" "$HR" "$R"
}
ok()   { printf '  %s✔%s %s\n' "$GRN" "$R" "$*"; }
info() { printf '  %sℹ%s %s\n' "$BLU" "$R" "$*"; }
warn() { printf '  %s⚠%s %s\n' "$YEL" "$R" "$*"; }
err()  { printf '  %s✖%s %s\n' "$RED" "$R" "$*" >&2; }
kv()   { printf '  %s%-26s%s %s\n' "$DIM" "$1" "$R" "$2"; }
die()  { err "$*"; printf '  %sПодробности в логе: %s%s\n' "$DIM" "$LOG" "$R" >&2; exit 1; }

banner() {
    echo
    printf '%s%s╔════════════════════════════════════════════════════════════╗%s\n' "$CYN" "$B" "$R"
    printf '%s%s║%s  %s%-40s%s %17s  %s%s║%s\n' "$CYN" "$B" "$R" "$GRN$B" "$SCRIPT_TITLE" "$R" "v${SCRIPT_VERSION}" "$R" "$CYN$B" "$R"
    printf '%s%s╚════════════════════════════════════════════════════════════╝%s\n' "$CYN" "$B" "$R"
}

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
    if [[ $def == Y ]]; then hint="Y/n"; else hint="y/N"; fi
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
echo "=== server4keymaster.sh v${SCRIPT_VERSION} — $(date '+%F %T') ===" >>"$LOG"

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
    echo "    1) Обновить настройки (домен / сертификат / ключ)"
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

EMAIL=${KM_EMAIL:-}
if [[ -z $EMAIL ]]; then
    prompt EMAIL "E-mail для уведомлений Let's Encrypt (Enter — без e-mail)" ""
fi
if [[ -n $EMAIL ]]; then ok "E-mail: ${EMAIL}"; else info "E-mail не указан"; fi

# SSH-ключ для SFTP-пользователя
KEY_DATA=""
KEEP_KEYS=0
ROOT_KEYS=""
if [[ -f /root/.ssh/authorized_keys ]]; then
    ROOT_KEYS=$(grep -E '^(ssh-|ecdsa-|sk-)' /root/.ssh/authorized_keys || true)
fi

echo
info "KeyMaster.py подключается по SFTP с ПРИВАТНЫМ ключом (uploadkey.pem, тип RSA)."
info "Нужен соответствующий ПУБЛИЧНЫЙ ключ (строка вида: ssh-rsa AAAA... comment)."
if [[ -n ${KM_PUBKEY:-} ]]; then
    KEY_DATA=$KM_PUBKEY
else
    if [[ -f $KEYS_FILE ]]; then
        key_hint="Enter — оставить текущий ключ ${KM_USER}"
    elif [[ -n $ROOT_KEYS ]]; then
        key_hint="Enter — взять ключи root"
    else
        key_hint="обязательно"
    fi
    while true; do
        prompt KEY_DATA "Публичный ключ (${key_hint})" ""
        if [[ -z $KEY_DATA ]]; then
            if [[ -f $KEYS_FILE ]]; then KEEP_KEYS=1; break; fi
            if [[ -n $ROOT_KEYS ]]; then KEY_DATA=$ROOT_KEYS; break; fi
            if (( ! HAVE_TTY )); then die "Не задан публичный ключ (KM_PUBKEY)"; fi
            err "Ключ не может быть пустым"
            continue
        fi
        break
    done
fi

if (( ! KEEP_KEYS )); then
    # валидация и проверка типа
    tmp_key=$(mktemp)
    KEY_OK=0; KEY_NON_RSA=0
    while IFS= read -r line; do
        [[ -z $line ]] && continue
        printf '%s\n' "$line" >"$tmp_key"
        if ssh-keygen -l -f "$tmp_key" >/dev/null 2>&1; then
            KEY_OK=$((KEY_OK + 1))
            if [[ $line != ssh-rsa* ]]; then KEY_NON_RSA=$((KEY_NON_RSA + 1)); fi
        else
            rm -f "$tmp_key"
            die "Некорректный публичный ключ: ${line:0:50}…"
        fi
    done <<<"$KEY_DATA"
    rm -f "$tmp_key"
    (( KEY_OK > 0 )) || die "Не найдено ни одного корректного ключа"
    ok "Ключей принято: ${KEY_OK}"
    if (( KEY_NON_RSA > 0 )); then
        warn "Не все ключи типа ssh-rsa. KeyMaster.py использует paramiko.RSAKey — для него нужен RSA-ключ."
    fi
else
    ok "Текущий ключ пользователя ${KM_USER} сохранён"
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
if (( ! KEEP_KEYS )); then
    printf '%s\n' "$KEY_DATA" >"$KEYS_FILE"
    chown root:root "$KEYS_FILE"; chmod 644 "$KEYS_FILE"
    ok "Публичный ключ установлен: ${KEYS_FILE}"
fi

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

# Самопроверка: отдаёт ли nginx challenge-файлы
PROBE_NAME="km-probe-$$"
PROBE_FILE="${ACME_ROOT}/.well-known/acme-challenge/${PROBE_NAME}"
echo "km-ok" >"$PROBE_FILE"
PROBE_RESULT=$(curl -s --max-time 5 -H "Host: ${DOMAIN}" "http://127.0.0.1/.well-known/acme-challenge/${PROBE_NAME}" || true)
rm -f "$PROBE_FILE"
if [[ $PROBE_RESULT == km-ok ]]; then
    ok "nginx отдаёт challenge-файлы для ${DOMAIN}"
else
    rollback_conf
    die "nginx не отдаёт /.well-known/ для ${DOMAIN}. Вероятно, другой server-блок перехватывает запросы."
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
        --non-interactive --agree-tos --keep-until-expiring)
    if [[ -n $EMAIL ]]; then CERTBOT_ARGS+=(-m "$EMAIL"); else CERTBOT_ARGS+=(--register-unsafely-without-email); fi
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
printf '%s%s╔════════════════════════════════════════════════════════════╗%s\n' "$GRN" "$B" "$R"
printf '%s%s║  ✔ Сервер готов к работе с KeyMaster.py                    ║%s\n' "$GRN" "$B" "$R"
printf '%s%s╚════════════════════════════════════════════════════════════╝%s\n' "$GRN" "$B" "$R"
echo
printf '  %sПропишите в KeyMaster.py (ПАРАМЕТРЫ СЕРВЕРА):%s\n\n' "$B" "$R"
printf '    server_ip        = "%s"\n' "${PUBLIC_IP:-IP_СЕРВЕРА}"
printf '    server_port      = %s\n' "$SSH_PORT"
printf '    username         = "%s"\n' "$KM_USER"
printf '    remote_folder    = "%s"\n' "$KM_HOME"
printf '    media_domain     = "%s"\n' "$MEDIA_URL"
printf '    private_key_path = "uploadkey.pem"   %s# приватный ключ RSA к загруженному публичному%s\n' "$DIM" "$R"
echo
printf '  %sПроверка вручную:%s\n' "$B" "$R"
printf '    sftp -i uploadkey.pem -P %s %s@%s\n' "$SSH_PORT" "$KM_USER" "${PUBLIC_IP:-IP_СЕРВЕРА}"
echo
printf '  %sПолезное:%s\n' "$B" "$R"
printf '    %s%s\n' "Логи nginx:   " "tail -f /var/log/nginx/keymaster.access.log"
printf '    %s%s\n' "Лог скрипта:  " "$LOG"
printf '    %s%s\n' "Конфиг nginx: " "$CONF_AVAIL"
printf '    %s%s\n' "Удаление:     " "запустите скрипт снова → пункт 2"
echo
