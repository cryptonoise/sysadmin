#!/bin/bash
# server4keymaster.sh - Настройка сервера для KeyMaster
# Запуск: curl -fsSL https://raw.githubusercontent.com/cryptonoise/sysadmin/refs/heads/main/server4keymaster.sh | bash

# === ВЕРСИЯ СКРИПТА ===
SCRIPT_VERSION="v2.6"
SCRIPT_NAME="KeyMaster Server Setup"

# === МЕТКА УСТАНОВКИ ===
MARKER_FILE="/etc/keymaster-server-setup.marker"

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[ℹ️]${NC} $1"; }
log_success() { echo -e "${GREEN}[✅]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[⚠️]${NC} $1"; }
log_error()   { echo -e "${RED}[❌]${NC} $1"; }
log_step()    { echo -e "\n${CYAN}────────────────────────────────${NC}"; echo -e "${CYAN}[⚙️]${NC} $1"; echo -e "${CYAN}────────────────────────────────${NC}\n"; }

# === Cloudflare IP ranges (единая переменная) ===
CLOUDFLARE_IPS='
    set_real_ip_from 103.21.244.0/22;
    set_real_ip_from 103.22.200.0/22;
    set_real_ip_from 103.31.4.0/22;
    set_real_ip_from 104.16.0.0/13;
    set_real_ip_from 104.24.0.0/14;
    set_real_ip_from 108.162.192.0/18;
    set_real_ip_from 131.0.72.0/22;
    set_real_ip_from 141.101.64.0/18;
    set_real_ip_from 162.158.0.0/15;
    set_real_ip_from 172.64.0.0/13;
    set_real_ip_from 173.245.48.0/20;
    set_real_ip_from 188.114.96.0/20;
    set_real_ip_from 190.93.240.0/20;
    set_real_ip_from 197.234.240.0/22;
    set_real_ip_from 198.41.128.0/17;
    set_real_ip_from 2400:cb00::/32;
    set_real_ip_from 2606:4700::/32;
    set_real_ip_from 2803:f800::/32;
    set_real_ip_from 2405:b500::/32;
    set_real_ip_from 2405:8100::/32;
    set_real_ip_from 2a06:98c0::/29;
    set_real_ip_from 2c0f:f248::/32;
    real_ip_header CF-Connecting-IP;'

# === ЗАГОЛОВОК ПРИ ЗАПУСКЕ ===
print_header() {
    echo ""
    echo -e "${RED}────────────────────────────────${NC}"
    echo -e "  ${GREEN}${SCRIPT_NAME}${NC}"
    echo -e "  Версия: ${CYAN}${SCRIPT_VERSION}${NC}"
    echo -e "${RED}────────────────────────────────${NC}"
    echo ""
}

print_header

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
   log_error "Скрипт должен быть запущен от имени root"
   exit 1
fi

# === ПРОВЕРКА МЕТКИ УСТАНОВКИ ===
if [[ -f "$MARKER_FILE" ]]; then
    log_warn "Обнаружена метка предыдущей установки: $MARKER_FILE"
    echo ""
    echo "📋 Скрипт уже запускался на этом сервере."
    echo "   Дата установки: $(cat "$MARKER_FILE" | head -1)"
    echo "   Домен: $(cat "$MARKER_FILE" | grep '^DOMAIN=' | cut -d'=' -f2)"
    echo "   Пользователь: $(cat "$MARKER_FILE" | grep '^USER=' | cut -d'=' -f2)"
    echo "   SSH порт: $(cat "$MARKER_FILE" | grep '^SSH_PORT=' | cut -d'=' -f2)"
    echo ""
    echo -e "${YELLOW}Выберите действие:${NC}"
    echo "   1 - Продолжить настройку (обновить конфигурацию)"
    echo "   2 - 🗑️  ОТКАТИТЬ все изменения"
    echo "   3 - Выйти без изменений"
    echo ""
    read -p "Введите номер [1-3]: " ACTION_CHOICE < /dev/tty
    
    case $ACTION_CHOICE in
        2)
            log_step "🗑️  Откат изменений"
            PREV_USER=$(grep '^USER=' "$MARKER_FILE" | cut -d'=' -f2)
            PREV_DOMAIN=$(grep '^DOMAIN=' "$MARKER_FILE" | cut -d'=' -f2)
            PREV_UPLOAD_DIR=$(grep '^UPLOAD_DIR=' "$MARKER_FILE" | cut -d'=' -f2)
            PREV_SSH_PORT=$(grep '^SSH_PORT=' "$MARKER_FILE" | cut -d'=' -f2)
            PREV_SSH_PORT=${PREV_SSH_PORT:-6934}
            
            echo ""
            log_info "Начало отката..."
            [[ -n "$PREV_USER" ]] && id "$PREV_USER" &>/dev/null && userdel -r "$PREV_USER" 2>/dev/null && log_success "Пользователь удалён"
            [[ -n "$PREV_UPLOAD_DIR" ]] && [[ -d "$PREV_UPLOAD_DIR" ]] && rm -rf "$PREV_UPLOAD_DIR" && log_success "Папка удалена"
            if [[ -n "$PREV_DOMAIN" ]]; then
                rm -f "/etc/nginx/sites-available/$PREV_DOMAIN" "/etc/nginx/sites-enabled/$PREV_DOMAIN" 2>/dev/null
                systemctl reload nginx 2>/dev/null || true
            fi
            SSH_CONFIG="/etc/ssh/sshd_config"
            grep -q "^Port $PREV_SSH_PORT" "$SSH_CONFIG" 2>/dev/null && sed -i "/^Port $PREV_SSH_PORT/d" "$SSH_CONFIG" && systemctl restart sshd 2>/dev/null || true
            command -v ufw &>/dev/null && { ufw delete allow $PREV_SSH_PORT/tcp 2>/dev/null; ufw delete allow 80/tcp 2>/dev/null; ufw delete allow 443/tcp 2>/dev/null; } || true
            rm -f "$MARKER_FILE"
            echo -e "${GREEN}✅ Откат завершён${NC}"
            exit 0
            ;;
        3) exit 0 ;;
        1) log_info "Продолжение настройки" ;;
        *) log_error "Неверный выбор"; exit 1 ;;
    esac
fi

[[ ! -f /etc/os-release ]] && { log_error "Не удалось определить ОС"; exit 1; }
source /etc/os-release
OS_ID=$ID
log_info "Обнаружена ОС: $PRETTY_NAME"

# === ШАГ 1: Ввод домена ===
log_step "Шаг 1: Настройка домена"
while true; do
    read -p "🌐 Введите домен для загрузки файлов: " MEDIA_DOMAIN < /dev/tty
    MEDIA_DOMAIN=$(echo "$MEDIA_DOMAIN" | xargs | sed 's|https\?://||' | sed 's|/$||')
    [[ -z "$MEDIA_DOMAIN" ]] && { log_error "Домен не может быть пустым"; continue; }
    [[ ! "$MEDIA_DOMAIN" =~ \. ]] && { log_error "Домен должен содержать точку"; continue; }
    [[ ! "$MEDIA_DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]] && { log_error "Недопустимые символы в домене"; continue; }
    break
done
log_success "Домен: $MEDIA_DOMAIN"

# === ШАГ 2-4: Пользователь, ключ, порт ===
log_step "Шаг 2: Пользователь"
read -p "👤 Имя пользователя [keymaster]: " UPLOAD_USER < /dev/tty
UPLOAD_USER=${UPLOAD_USER:-keymaster}
[[ -z "$UPLOAD_USER" ]] && { log_error "Имя не может быть пустым"; exit 1; }
log_success "Пользователь: $UPLOAD_USER"

log_step "Шаг 3: SSH-ключ"
echo "🔑 Введите публичный SSH-ключ:"
read -r SSH_PUBLIC_KEY < /dev/tty
[[ -z "$SSH_PUBLIC_KEY" ]] && { log_error "Ключ не может быть пустым"; exit 1; }
log_success "Ключ принят"

log_step "Шаг 4: SSH-порт"
read -p "🔌 Порт [6934]: " SSH_PORT < /dev/tty
SSH_PORT=${SSH_PORT:-6934}
[[ ! "$SSH_PORT" =~ ^[0-9]+$ || "$SSH_PORT" -lt 1 || "$SSH_PORT" -gt 65535 ]] && { log_error "Неверный порт"; exit 1; }
[[ "$SSH_PORT" == "22" ]] && log_warn "Порт 22 — стандартный"
log_success "Порт: $SSH_PORT"

# === ШАГ 5: Установка пакетов ===
log_step "Шаг 5: Установка пакетов"
case $OS_ID in
    ubuntu|debian)
        apt-get update
        apt-get install -y nginx openssh-server curl wget ufw certbot python3-certbot-nginx
        ;;
    centos|rhel|fedora|almalinux|rocky)
        command -v dnf &>/dev/null && dnf install -y nginx openssh-server curl wget firewalld certbot || yum install -y nginx openssh-server curl wget firewalld certbot
        ;;
    *) log_error "Неизвестная ОС: $OS_ID"; exit 1 ;;
esac
log_success "Пакеты установлены"

# === ШАГ 6-8: Пользователь, SSH, папка ===
log_step "Шаг 6: Создание пользователя"
id "$UPLOAD_USER" &>/dev/null || { useradd -m -s /bin/bash -G www-data "$UPLOAD_USER" 2>/dev/null || useradd -m -s /bin/bash "$UPLOAD_USER"; log_success "Создан"; }

log_step "Шаг 7: Настройка SSH"
SSH_DIR="/home/$UPLOAD_USER/.ssh"
mkdir -p "$SSH_DIR"
echo "$SSH_PUBLIC_KEY" > "$SSH_DIR/authorized_keys"
chmod 700 "$SSH_DIR"; chmod 600 "$SSH_DIR/authorized_keys"
chown -R "$UPLOAD_USER:$UPLOAD_USER" "$SSH_DIR"
SSH_CONFIG="/etc/ssh/sshd_config"
grep -q "^Port $SSH_PORT" "$SSH_CONFIG" 2>/dev/null || sed -i "/^#Port 22/a Port $SSH_PORT" "$SSH_CONFIG" 2>/dev/null || echo "Port $SSH_PORT" >> "$SSH_CONFIG"
systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
log_success "SSH настроен"

log_step "Шаг 8: Папка загрузок"
UPLOAD_DIR="/var/www/uploads"
mkdir -p "$UPLOAD_DIR"
chown -R "$UPLOAD_USER:www-data" "$UPLOAD_DIR"
chmod 755 "$UPLOAD_DIR"
log_success "Папка готова"

# === ШАГ 9: Проверка наличия сертификата ===
log_step "Шаг 9: Проверка SSL-сертификата"
CERT_PATH="/etc/letsencrypt/live/$MEDIA_DOMAIN/fullchain.pem"
HAS_CERT=false

if [[ -f "$CERT_PATH" ]]; then
    log_success "✅ Сертификат найден: $CERT_PATH"
    HAS_CERT=true
else
    log_warn "Сертификат не найден: $CERT_PATH"
fi

# === ШАГ 10: Попытка получить сертификат (если нет) ===
if [[ "$HAS_CERT" == "false" ]]; then
    log_step "Шаг 10: Получение сертификата"
    log_info "Проверка доступности домена..."
    if curl -s --connect-timeout 5 "http://$MEDIA_DOMAIN" > /dev/null 2>&1; then
        log_info "Запуск certbot..."
        if certbot --nginx -d "$MEDIA_DOMAIN" -d "www.$MEDIA_DOMAIN" --expand --force-renewal --non-interactive --agree-tos --redirect --email "admin@$MEDIA_DOMAIN" 2>&1 | tee /tmp/certbot.log; then
            log_success "Сертификат получен!"
            HAS_CERT=true
        else
            log_warn "Не удалось получить сертификат (продолжаем с HTTP)"
        fi
    else
        log_warn "Домен недоступен по HTTP — пропуск certbot"
    fi
fi

# === ШАГ 11: Генерация nginx конфига (ВСЕГДА с HTTPS если сертификат есть) ===
log_step "Шаг 11: Настройка nginx"
NGINX_CONF="/etc/nginx/sites-available/$MEDIA_DOMAIN"
NGINX_LINK="/etc/nginx/sites-enabled/$MEDIA_DOMAIN"

log_info "Создание конфигурации..."

if [[ "$HAS_CERT" == "true" ]]; then
    # === КОНФИГ С HTTPS ===
    cat > "$NGINX_CONF" << EOF
$CLOUDFLARE_IPS

# HTTP → HTTPS redirect
server {
    listen 80;
    listen [::]:80;
    server_name $MEDIA_DOMAIN www.$MEDIA_DOMAIN;
    return 301 https://\$host\$request_uri;
}

# HTTPS server
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $MEDIA_DOMAIN www.$MEDIA_DOMAIN;

    root $UPLOAD_DIR;
    index index.html;

    ssl_certificate /etc/letsencrypt/live/$MEDIA_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$MEDIA_DOMAIN/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    client_max_body_size 100M;

    add_header Access-Control-Allow-Origin *;
    add_header Access-Control-Allow-Methods 'GET, OPTIONS';
    add_header Access-Control-Allow-Headers 'Content-Type';
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;

    location / {
        try_files \$uri \$uri/ =404;
        autoindex off;
        types {
            image/jpeg jpg jpeg; image/png png; image/webp webp;
            video/mp4 mp4; video/quicktime mov; video/x-msvideo avi;
            video/x-matroska mkv; video/x-ms-wmv wmv;
        }
        default_type application/octet-stream;
        add_header X-Content-Type-Options nosniff;
        add_header X-Frame-Options SAMEORIGIN;
    }
    location ~ /\. { deny all; return 404; }
    access_log /var/log/nginx/${MEDIA_DOMAIN}_access.log;
    error_log /var/log/nginx/${MEDIA_DOMAIN}_error.log;
}
EOF
    log_success "Конфиг создан с HTTPS"
else
    # === КОНФИГ ТОЛЬКО HTTP ===
    cat > "$NGINX_CONF" << EOF
$CLOUDFLARE_IPS

server {
    listen 80;
    listen [::]:80;
    server_name $MEDIA_DOMAIN www.$MEDIA_DOMAIN;
    root $UPLOAD_DIR;
    index index.html;
    client_max_body_size 100M;
    add_header Access-Control-Allow-Origin *;
    add_header Access-Control-Allow-Methods 'GET, OPTIONS';
    add_header Access-Control-Allow-Headers 'Content-Type';
    location / {
        try_files \$uri \$uri/ =404;
        autoindex off;
        types {
            image/jpeg jpg jpeg; image/png png; image/webp webp;
            video/mp4 mp4; video/quicktime mov; video/x-msvideo avi;
            video/x-matroska mkv; video/x-ms-wmv wmv;
        }
        default_type application/octet-stream;
    }
    location ~ /\. { deny all; return 404; }
    access_log /var/log/nginx/${MEDIA_DOMAIN}_access.log;
    error_log /var/log/nginx/${MEDIA_DOMAIN}_error.log;
}
EOF
    log_success "Конфиг создан (HTTP)"
fi

[[ ! -L "$NGINX_LINK" ]] && [[ ! -f "$NGINX_LINK" ]] && ln -s "$NGINX_CONF" "$NGINX_LINK"
nginx -t
systemctl enable nginx
systemctl reload nginx
log_success "nginx перезагружен"

# === ШАГ 12: Автообновление сертификата ===
log_step "Шаг 12: Автообновление"
if [[ "$HAS_CERT" == "true" ]]; then
    systemctl enable certbot.timer 2>/dev/null || true
    systemctl start certbot.timer 2>/dev/null || true
    [[ -f /etc/cron.d/certbot ]] && log_success "Cron-задача существует"
    log_info "Тест автообновления (dry-run)..."
    timeout 90 certbot renew --dry-run 2>&1 | tee /tmp/certbot-dryrun.log | grep -qi "congratulations" && log_success "✅ Автообновление работает" || log_warn "⚠️ Проверка завершилась с предупреждениями"
else
    log_warn "Пропуск (нет сертификата)"
fi

# === ШАГ 13-16: Фаервол, права, тест, метка ===
log_step "Шаг 13: Фаервол"
if command -v ufw &>/dev/null; then
    ufw allow 22/tcp; ufw allow $SSH_PORT/tcp; ufw allow 80/tcp; ufw allow 443/tcp 2>/dev/null || true
    echo "y" | ufw enable 2>/dev/null || true
    log_success "UFW настроен"
fi

log_step "Шаг 14: Права доступа"
chmod 755 "$UPLOAD_DIR"
chown -R "$UPLOAD_USER:www-data" "$UPLOAD_DIR"
find "$UPLOAD_DIR" -type f -exec chmod 644 {} \; 2>/dev/null || true
find "$UPLOAD_DIR" -type d -exec chmod 755 {} \; 2>/dev/null || true
log_success "Права настроены"

log_step "Шаг 15: Тестовый файл"
TEST_FILE="$UPLOAD_DIR/test_keymaster.txt"
echo "KeyMaster server is ready! $(date)" > "$TEST_FILE"
chown "$UPLOAD_USER:www-data" "$TEST_FILE"
chmod 644 "$TEST_FILE"
log_success "Файл создан"

log_step "Шаг 16: Метка установки"
cat > "$MARKER_FILE" << EOF
INSTALLED_AT=$(date '+%Y-%m-%d %H:%M:%S')
SCRIPT_VERSION=$SCRIPT_VERSION
DOMAIN=$MEDIA_DOMAIN
USER=$UPLOAD_USER
UPLOAD_DIR=$UPLOAD_DIR
SSH_PORT=$SSH_PORT
EOF
chmod 644 "$MARKER_FILE"
log_success "Метка создана"

# === ШАГ 17: Итог ===
log_step "✅ Настройка завершена!"
echo "╔════════════════════════════════════════════════════╗"
echo "║  🎉 Сервер KeyMaster готов к работе!              ║"
echo "╚════════════════════════════════════════════════════╝"
echo ""
echo "📋 Параметры:"
echo "   • Домен:            $MEDIA_DOMAIN"
echo "   • Пользователь:     $UPLOAD_USER"
echo "   • SSH порт:         $SSH_PORT"
echo "   • Папка:            $UPLOAD_DIR"
[[ "$HAS_CERT" == "true" ]] && echo "   • Веб-доступ:       🔗 https://$MEDIA_DOMAIN/" || echo "   • Веб-доступ:       🔗 http://$MEDIA_DOMAIN/"
echo ""
echo "🧪 Проверка (кликните):"
[[ "$HAS_CERT" == "true" ]] && echo -e "   🔗 https://$MEDIA_DOMAIN/test_keymaster.txt" || echo -e "   🔗 http://$MEDIA_DOMAIN/test_keymaster.txt"
echo "   📡 ssh -p $SSH_PORT $UPLOAD_USER@$(hostname -I | awk '{print $1}' | head -1)"
echo ""

if [[ "$HAS_CERT" == "true" ]]; then
    echo "☁️  Cloudflare Full (strict):"
    echo "   • SSL/TLS → Full (strict)"
    echo "   • DNS → A: $(hostname -I | awk '{print $1}' | head -1) (🟠 Proxied)"
    echo ""
    echo "🔄 Автообновление: ✅ включено"
    echo ""
    echo "⚠️  Если ошибка 403/1000:"
    echo "   1. Проверьте, что nginx слушает порт 443: ss -tlnp | grep :443"
    echo "   2. Убедитесь, что нет конфликта с Docker/другими сервисами"
    echo "   3. Временно отключите прокси в Cloudflare для теста"
    echo "   4. Проверьте: curl -I --resolve $MEDIA_DOMAIN:443:$(hostname -I | awk '{print $1}' | head -1) https://$MEDIA_DOMAIN/test_keymaster.txt"
    echo ""
fi

echo "🗑️ Откат: перезапустите скрипт → опция 2"
echo ""
log_success "Готово! 🚀"
