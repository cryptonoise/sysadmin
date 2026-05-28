#!/bin/bash
# Запуск: curl -fsSL https://raw.githubusercontent.com/cryptonoise/sysadmin/refs/heads/main/install-keymaster-native.sh | bash
SCRIPT_VERSION="v1.0-Native-SSL"
SCRIPT_NAME="KeyMaster Native Installer"
MARKER_FILE="/etc/keymaster-native-setup.marker"
UPLOAD_DIR="/var/www/keymaster-media"
TEMP_CONF="/etc/nginx/sites-available/keymaster-temp"
MAIN_CONF="/etc/nginx/sites-available/keymaster"

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[ℹ️]${NC} $1"; }
log_success() { echo -e "${GREEN}[✅]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[⚠️]${NC} $1"; }
log_error()   { echo -e "${RED}[❌]${NC} $1"; }
log_step()    { echo -e "\n${CYAN}────────────────────────────────${NC}\n${CYAN}[ ⚙️ ]${NC} $1\n${CYAN}────────────────────────────────${NC}\n"; }
log_detail()  { echo -e "   ${CYAN}→${NC} $1"; }

print_header() {
    echo ""
    echo -e "${RED}────────────────────────────────${NC}"
    echo -e "  ${GREEN}${SCRIPT_NAME}${NC}"
    echo -e "  Версия: ${CYAN}${SCRIPT_VERSION}${NC}"
    echo -e "${RED}────────────────────────────────${NC}"
    echo ""
}

print_header

if [[ $EUID -ne 0 ]]; then
    log_error "Запустите от имени root"
    exit 1
fi

# === ПРОВЕРКА МЕТКИ ===
if [[ -f "$MARKER_FILE" ]]; then
    log_warn "Найдена метка предыдущей установки"
    PREV_DOMAIN=$(grep '^DOMAIN=' "$MARKER_FILE" | cut -d'=' -f2)
    echo "📋 Скрипт уже запускался для домена: $PREV_DOMAIN"
    echo ""
    echo -e "${YELLOW}Действие:${NC}"
    echo "   1 - Пересоздать конфиги (обновить SSL/настройки)"
    echo "   2 - 🗑️  Полный откат (удалить сайт и сертификаты)"
    echo "   3 - Выход"
    read -p "Выбор [1-3]: " ACTION_CHOICE < /dev/tty
    
    case $ACTION_CHOICE in
        2)
            log_step "🗑️  Откат"
            # Удаляем конфиги nginx
            rm -f "$MAIN_CONF" /etc/nginx/sites-enabled/keymaster
            rm -f "$TEMP_CONF" /etc/nginx/sites-enabled/keymaster-temp
            
            # Удаляем папку файлов
            [[ -d "$UPLOAD_DIR" ]] && rm -rf "$UPLOAD_DIR"
            
            # Удаляем сертификат (опционально, можно оставить)
            if [[ -d "/etc/letsencrypt/live/$PREV_DOMAIN" ]]; then
                read -p "Удалить SSL сертификат для $PREV_DOMAIN? [y/N]: " DEL_CERT < /dev/tty
                if [[ "$DEL_CERT" =~ ^[Yy]$ ]]; then
                    certbot delete --cert-name "$PREV_DOMAIN" --non-interactive || true
                fi
            fi
            
            nginx -t && systemctl reload nginx 2>/dev/null || true
            rm -f "$MARKER_FILE"
            log_success "Откат выполнен"; exit 0
            ;;
        3) exit 0 ;;
        1) log_info "Обновление конфигурации..." ;;
        *) log_error "Неверный выбор"; exit 1 ;;
    esac
fi

[[ ! -f /etc/os-release ]] && { log_error "Неизвестная ОС"; exit 1; }
source /etc/os-release
OS_ID=$ID
log_info "ОС: $PRETTY_NAME"

# === ШАГ 1: Домен ===
log_step "Шаг 1: Домен"
while true; do
    read -p "🌐 Введите домен (например, media.norest.art): " MEDIA_DOMAIN < /dev/tty
    MEDIA_DOMAIN=$(echo "$MEDIA_DOMAIN" | xargs | sed 's|https\?://||' | sed 's|/$||')
    [[ -z "$MEDIA_DOMAIN" ]] && { log_error "Пусто"; continue; }
    [[ ! "$MEDIA_DOMAIN" =~ \. ]] && { log_error "Нужна точка"; continue; }
    break
done
log_success "Домен: $MEDIA_DOMAIN"

# === ШАГ 2: Установка Nginx и Certbot ===
log_step "Шаг 2: Проверка Nginx и Certbot"
install_deps() {
    case $OS_ID in
        ubuntu|debian)
            apt-get update
            apt-get install -y nginx certbot python3-certbot-nginx curl
            ;;
        centos|rhel|fedora|almalinux|rocky)
            yum install -y epel-release
            yum install -y nginx certbot python3-certbot-nginx curl
            systemctl enable --now nginx
            ;;
        *) log_error "ОС не поддерживается"; exit 1 ;;
    esac
}

if ! command -v nginx &>/dev/null; then
    log_warn "Nginx не найден. Устанавливаем..."
    install_deps
    log_success "Nginx установлен"
else
    log_success "Nginx уже установлен: $(nginx -v 2>&1)"
fi

if ! command -v certbot &>/dev/null; then
    log_warn "Certbot не найден. Устанавливаем..."
    install_deps
    log_success "Certbot установлен"
fi

# === ШАГ 3: Получение SSL Сертификата ===
log_step "Шаг 3: SSL Сертификат"

if [[ -d "/etc/letsencrypt/live/$MEDIA_DOMAIN" ]]; then
    log_info "Сертификат для $MEDIA_DOMAIN уже существует. Пропускаем генерацию."
else
    log_detail "Создаем временный конфиг Nginx на порту 80 для проверки..."
    
    cat > "$TEMP_CONF" <<EOF
server {
    listen 80;
    server_name $MEDIA_DOMAIN www.$MEDIA_DOMAIN;
    location / {
        return 200 'OK';
        add_header Content-Type text/plain;
    }
}
EOF
    
    ln -sf "$TEMP_CONF" /etc/nginx/sites-enabled/
    nginx -t && systemctl reload nginx

    log_detail "Запрос сертификата через Let's Encrypt..."
    certbot certonly --nginx -d "$MEDIA_DOMAIN" --non-interactive --agree-tos -m admin@"$MEDIA_DOMAIN" --keep-until-expiring --expand

    if [[ $? -eq 0 ]]; then
        log_success "Сертификат успешно получен!"
    else
        log_error "Ошибка получения сертификата. Проверьте DNS A-запись для $MEDIA_DOMAIN"
        rm -f /etc/nginx/sites-enabled/keymaster-temp
        rm -f "$TEMP_CONF"
        nginx -t && systemctl reload nginx
        exit 1
    fi

    log_detail "Удаляем временный конфиг..."
    rm -f /etc/nginx/sites-enabled/keymaster-temp
    rm -f "$TEMP_CONF"
    nginx -t && systemctl reload nginx
fi

# === ШАГ 4: Подготовка папок ===
log_step "Шаг 4: Папки"
mkdir -p "$UPLOAD_DIR"
chown -R www-data:www-data "$UPLOAD_DIR"
chmod 755 "$UPLOAD_DIR"

echo "<h1>KeyMaster Native HTTPS Ready</h1><p>Files are served by System Nginx.</p>" > "$UPLOAD_DIR/index.html"
log_success "Папка создана: $UPLOAD_DIR"

# === ШАГ 5: Основной конфиг Nginx (HTTPS) ===
log_step "Шаг 5: Конфиг Nginx (HTTPS)"

cat > "$MAIN_CONF" << EOF
server {
    listen 80;
    server_name $MEDIA_DOMAIN www.$MEDIA_DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $MEDIA_DOMAIN www.$MEDIA_DOMAIN;

    # Пути к сертификатам
    ssl_certificate /etc/letsencrypt/live/$MEDIA_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$MEDIA_DOMAIN/privkey.pem;

    # Настройки SSL
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    add_header Strict-Transport-Security "max-age=63072000" always;
    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";

    # Корневая папка KeyMaster
    root $UPLOAD_DIR;
    index index.html;

    client_max_body_size 100M;

    # Кэширование медиафайлов
    location ~* \.(jpg|jpeg|png|gif|webp|mp4|mov|avi|mkv|wmv)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        add_header Access-Control-Allow-Origin * always;
        access_log off;
    }

    # CORS для внешних запросов (OpenAI и т.д.)
    add_header Access-Control-Allow-Origin * always;
    add_header Access-Control-Allow-Methods 'GET, OPTIONS' always;
    add_header Access-Control-Allow-Headers 'Content-Type, Accept, Authorization' always;

    location / {
        try_files \$uri \$uri/ =404;
        autoindex off;
    }

    location ~ /\. {
        deny all;
        return 404;
    }
    
    access_log /var/log/nginx/keymaster-access.log;
    error_log /var/log/nginx/keymaster-error.log warn;
}
EOF

ln -sf "$MAIN_CONF" /etc/nginx/sites-enabled/
nginx -t

if [[ $? -eq 0 ]]; then
    systemctl restart nginx
    log_success "Конфиг применен и Nginx перезагружен"
else
    log_error "Ошибка в конфиге Nginx. Проверьте синтаксис."
    exit 1
fi

# === ШАГ 6: Метка ===
cat > "$MARKER_FILE" << EOF
INSTALLED_AT=$(date '+%Y-%m-%d %H:%M:%S')
SCRIPT_VERSION=$SCRIPT_VERSION
DOMAIN=$MEDIA_DOMAIN
UPLOAD_DIR=$UPLOAD_DIR
EOF
chmod 644 "$MARKER_FILE"

# === ИТОГ ===
log_step "✅ Готово!"
echo -e "${RED}────────────────────────────────${NC}"
echo "🎉 KeyMaster Native установлен!"
echo -e "${RED}────────────────────────────────${NC}"
echo ""
echo "🔗 Адрес: https://$MEDIA_DOMAIN"
echo "📁 Файлы лежат в: $UPLOAD_DIR"
echo ""
echo "⚠️ Cloudflare:"
echo "   • A-запись: $MEDIA_DOMAIN -> Твой IP"
echo "   • Proxy Status: OFF (Серое облако) для прямого доступа"
echo "   • SSL/TLS Mode: Full (Strict)"
echo ""
echo "🧪 Проверка:"
echo "   🔗 https://$MEDIA_DOMAIN/test_keymaster.txt"
echo ""
