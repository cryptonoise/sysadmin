#!/bin/bash
# Запуск: curl -fsSL https://raw.githubusercontent.com/cryptonoise/sysadmin/refs/heads/main/server4keymaster.sh | bash
# === ВЕРСИЯ СКРИПТА ===
SCRIPT_VERSION="v2.0-UniSSL"
SCRIPT_NAME="KeyMaster Server (Universal SSL)"
# === МЕТКА УСТАНОВКИ ===
MARKER_FILE="/etc/keymaster-server-setup.marker"
DOCKER_DIR="/opt/keymaster-docker"
UPLOAD_DIR_HOST="/var/www/keymaster-media"
CERTBOT_WEBROOT="/var/www/certbot"
set -e

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

# Проверка root
if [[ $EUID -ne 0 ]]; then
    log_error "Запустите от имени root"
    exit 1
fi

# === ПРОВЕРКА МЕТКИ ===
if [[ -f "$MARKER_FILE" ]]; then
    log_warn "Найдена метка предыдущей установки"
    echo "📋 Скрипт уже запускался."
    echo "   Домен: $(grep '^DOMAIN=' "$MARKER_FILE" | cut -d'=' -f2)"
    echo ""
    echo -e "${YELLOW}Действие:${NC}"
    echo "   1 - Пересоздать контейнер"
    echo "   2 - 🗑️  Полный откат (удалить всё)"
    echo "   3 - Выход"
    read -p "Выбор [1-3]: " ACTION_CHOICE < /dev/tty
    
    case $ACTION_CHOICE in
        2)
            log_step "🗑️  Откат"
            if command -v docker &>/dev/null; then
                cd "$DOCKER_DIR" 2>/dev/null && docker compose down 2>/dev/null || true
                docker rm -f keymaster 2>/dev/null || true
            fi
            [[ -d "$DOCKER_DIR" ]] && rm -rf "$DOCKER_DIR"
            [[ -d "$UPLOAD_DIR_HOST" ]] && rm -rf "$UPLOAD_DIR_HOST"
            [[ -d "$CERTBOT_WEBROOT" ]] && rm -rf "$CERTBOT_WEBROOT"
            
            # Удаляем блок webroot из основного nginx если есть
            if command -v nginx &>/dev/null; then
                sed -i '/location \/\.well-known\/acme-challenge/d' /etc/nginx/sites-available/*.conf 2>/dev/null || true
                sed -i '/root \/var\/www\/certbot;/d' /etc/nginx/sites-available/*.conf 2>/dev/null || true
                nginx -t && systemctl reload nginx 2>/dev/null || true
            fi
            
            rm -f "$MARKER_FILE"
            log_success "Откат выполнен"; exit 0
            ;;
        3) exit 0 ;;
        1) log_info "Продолжаем..." ;;
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
    read -p "🌐 Домен (например, media.norest.art): " MEDIA_DOMAIN < /dev/tty
    MEDIA_DOMAIN=$(echo "$MEDIA_DOMAIN" | xargs | sed 's|https\?://||' | sed 's|/$||')
    [[ -z "$MEDIA_DOMAIN" ]] && { log_error "Пусто"; continue; }
    [[ ! "$MEDIA_DOMAIN" =~ \. ]] && { log_error "Нужна точка"; continue; }
    break
done
log_success "Домен: $MEDIA_DOMAIN"

# === ШАГ 2: Пользователь ===
log_step "Шаг 2: Пользователь"
read -p "👤 Имя пользователя [keymaster]: " UPLOAD_USER < /dev/tty
UPLOAD_USER=${UPLOAD_USER:-keymaster}
if id "$UPLOAD_USER" &>/dev/null; then
    log_detail "Пользователь существует"
else
    useradd -m -s /bin/bash "$UPLOAD_USER"
    log_success "Пользователь создан"
fi

# === ШАГ 3: Docker и Certbot ===
log_step "Шаг 3: Установка Docker и Certbot"
install_deps() {
    case $OS_ID in
        ubuntu|debian)
            apt-get update
            apt-get install -y ca-certificates curl gnupg lsb-release software-properties-common
            mkdir -p /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null || true
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$OS_ID $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
            apt-get update
            apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin certbot python3-certbot-nginx
            ;;
        centos|rhel|fedora|almalinux|rocky)
            yum install -y yum-utils epel-release
            yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin certbot python3-certbot-nginx
            systemctl enable --now docker
            ;;
        *) log_error "ОС не поддерживается"; exit 1 ;;
    esac
}

command -v docker &>/dev/null || { log_warn "Ставим Docker..."; install_deps; }
command -v certbot &>/dev/null || { log_warn "Ставим Certbot..."; install_deps; }

if ! docker compose version &>/dev/null; then
    log_error "Нет docker-compose"; exit 1
fi

# === ШАГ 4: Получение SSL Сертификата ===
log_step "Шаг 4: SSL Сертификат"

# Создаем папку для webroot
mkdir -p "$CERTBOT_WEBROOT"

if [[ -d "/etc/letsencrypt/live/$MEDIA_DOMAIN" ]]; then
    log_info "Сертификат уже есть. Пропускаем."
else
    if command -v nginx &>/dev/null; then
        # --- СЦЕНАРИЙ А: NGINX ЕСТЬ (Webroot) ---
        log_info "Обнаружен системный Nginx. Используем метод Webroot."
        
        # Добавляем временный блок в основной nginx, чтобы certbot мог положить файл
        # Ищем основной конфиг или создаем общий сниппет
        # Для простоты добавим в sites-enabled/default или создадим новый conf
        
        # Проверяем, есть ли уже такой location в каком-то активном сайте
        if ! grep -r "acme-challenge" /etc/nginx/sites-enabled/ 2>/dev/null | grep -q "."; then
            log_detail "Добавляем поддержку .well-known в основной Nginx..."
            
            # Создаем общий конфиг для certbot, который подключается ко всем серверам
            cat > /etc/nginx/conf.d/certbot-webroot.conf <<'EOF'
location /.well-known/acme-challenge/ {
    root /var/www/certbot;
}
EOF
            nginx -t && systemctl reload nginx
        fi

        log_detail "Запрос сертификата через Webroot..."
        certbot certonly --webroot -w "$CERTBOT_WEBROOT" -d "$MEDIA_DOMAIN" --non-interactive --agree-tos -m admin@"$MEDIA_DOMAIN" --keep-until-expiring --expand

        if [[ $? -ne 0 ]]; then
            log_error "Ошибка получения сертификата. Проверьте DNS A-запись для $MEDIA_DOMAIN"
            exit 1
        fi
        
        # Очищаем временный конфиг, так как сертификат получен
        rm -f /etc/nginx/conf.d/certbot-webroot.conf
        nginx -t && systemctl reload nginx
        log_success "Сертификат получен (Webroot)"

    else
        # --- СЦЕНАРИЙ Б: NGINX НЕТ (Standalone/Temp Nginx) ---
        log_info "Системный Nginx не найден. Устанавливаем временный Nginx для проверки."
        
        # Ставим nginx если нет (зависимость certbot-nginx может поставить его)
        if ! command -v nginx &>/dev/null; then
             case $OS_ID in
                ubuntu|debian) apt-get install -y nginx ;;
                centos|rhel*) yum install -y nginx ;;
             esac
        fi

        log_detail "Создаем временный конфиг на порту 80..."
        cat > /etc/nginx/sites-available/keymaster-temp.conf <<EOF
server {
    listen 80;
    server_name $MEDIA_DOMAIN;
    location / {
        return 200 'OK';
        add_header Content-Type text/plain;
    }
}
EOF
        ln -sf /etc/nginx/sites-available/keymaster-temp.conf /etc/nginx/sites-enabled/
        nginx -t && systemctl restart nginx

        log_detail "Запрос сертификата через Nginx plugin..."
        certbot certonly --nginx -d "$MEDIA_DOMAIN" --non-interactive --agree-tos -m admin@"$MEDIA_DOMAIN" --keep-until-expiring --expand

        if [[ $? -ne 0 ]]; then
            log_error "Ошибка получения сертификата."
            rm -f /etc/nginx/sites-enabled/keymaster-temp.conf
            rm -f /etc/nginx/sites-available/keymaster-temp.conf
            exit 1
        fi

        log_detail "Удаляем временный конфиг..."
        rm -f /etc/nginx/sites-enabled/keymaster-temp.conf
        rm -f /etc/nginx/sites-available/keymaster-temp.conf
        nginx -t && systemctl restart nginx
        log_success "Сертификат получен (Temp Nginx)"
    fi
fi

# === ШАГ 5: Подготовка папок ===
log_step "Шаг 5: Папки"
NGINX_CONF_DIR="$DOCKER_DIR/nginx"
mkdir -p "$UPLOAD_DIR_HOST" "$NGINX_CONF_DIR" "$DOCKER_DIR"

chown -R "$UPLOAD_USER:33" "$UPLOAD_DIR_HOST"
chmod 775 "$UPLOAD_DIR_HOST"
echo "<h1>KeyMaster HTTPS Ready</h1>" > "$UPLOAD_DIR_HOST/index.html"
chown "$UPLOAD_USER:33" "$UPLOAD_DIR_HOST/index.html"

# === ШАГ 6: Проверка порта 8081 ===
log_step "Шаг 6: Проверка порта 8081"
PORT_TO_USE=8081
if ss -tlnp | grep ":$PORT_TO_USE " &>/dev/null; then
    log_error "Порт $PORT_TO_USE занят!"
    log_detail "Кто занял:"
    ss -tlnp | grep ":$PORT_TO_USE "
    log_error "Освободите порт или измените переменную PORT_TO_USE в скрипте."
    exit 1
else
    log_success "Порт $PORT_TO_USE свободен"
fi

# === ШАГ 7: Конфиг Nginx (Внутри Docker) ===
log_step "Шаг 7: Конфиг Nginx (Docker)"
NGINX_CONF_FILE="$NGINX_CONF_DIR/default.conf"

cat > "$NGINX_CONF_FILE" << 'NGINX_EOF'
proxy_read_timeout 300s;
proxy_send_timeout 300s;
send_timeout 300s;

# Cloudflare IPs
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
set_real_ip_recursive on;
real_ip_header CF-Connecting-IP;

sendfile on;
tcp_nopush on;
tcp_nodelay on;
keepalive_timeout 65;

gzip on;
gzip_vary on;
gzip_proxied any;
gzip_comp_level 6;
gzip_types text/plain text/css application/json application/javascript;

# HTTP Redirect
server {
    listen 80;
    server_name MEDIA_DOMAIN_PLACEHOLDER www.MEDIA_DOMAIN_PLACEHOLDER;
    return 301 https://$host$request_uri;
}

# HTTPS Server
server {
    listen 443 ssl http2;
    server_name MEDIA_DOMAIN_PLACEHOLDER www.MEDIA_DOMAIN_PLACEHOLDER;
    
    ssl_certificate /etc/letsencrypt/live/MEDIA_DOMAIN_PLACEHOLDER/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/MEDIA_DOMAIN_PLACEHOLDER/privkey.pem;
    
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;

    root /usr/share/nginx/html;
    index index.html;
    client_max_body_size 100M;

    location ~* \.(jpg|jpeg|png|gif|webp|mp4|mov|avi|mkv)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        add_header Access-Control-Allow-Origin * always;
    }

    add_header Access-Control-Allow-Origin * always;
    add_header X-Content-Type-Options nosniff always;

    location / {
        try_files $uri $uri/ =404;
    }
}
NGINX_EOF

sed -i "s/MEDIA_DOMAIN_PLACEHOLDER/$MEDIA_DOMAIN/g" "$NGINX_CONF_FILE"
log_success "Конфиг создан"

# === ШАГ 8: Docker Compose ===
log_step "Шаг 8: Docker Compose"
COMPOSE_FILE="$DOCKER_DIR/docker-compose.yml"

cat > "$COMPOSE_FILE" << EOF
version: '3.8'
services:
  keymaster:
    image: nginx:alpine
    container_name: keymaster
    restart: unless-stopped
    ports:
      - "$PORT_TO_USE:80"
      - "443:443"
    volumes:
      - ./nginx/default.conf:/etc/nginx/conf.d/default.conf:ro
      - ${UPLOAD_DIR_HOST}:/usr/share/nginx/html:rw
      - /etc/letsencrypt:/etc/letsencrypt:ro
    networks:
      - web-net

networks:
  web-net:
    driver: bridge
EOF

log_success "docker-compose.yml создан"

# === ШАГ 9: Запуск ===
log_step "Шаг 9: Запуск"
cd "$DOCKER_DIR"
docker compose up -d
sleep 3

if docker ps --filter name=keymaster --format '{{.Status}}' | grep -q "Up"; then
    log_success "Контейнер запущен"
else
    log_error "Ошибка запуска. Логи: docker logs keymaster"
    exit 1
fi

# === ШАГ 10: Тест ===
log_step "Шаг 10: Тест"
TEST_FILE="$UPLOAD_DIR_HOST/test_keymaster.txt"
echo "KeyMaster HTTPS OK! $(date)" > "$TEST_FILE"
chown "$UPLOAD_USER:33" "$TEST_FILE"

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -k "https://127.0.0.1/test_keymaster.txt" 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" == "200" ]]; then
    log_success "HTTPS работает (Код: $HTTP_CODE)"
else
    log_warn "HTTPS код: $HTTP_CODE"
fi

# === ШАГ 11: Метка ===
cat > "$MARKER_FILE" << EOF
INSTALLED_AT=$(date '+%Y-%m-%d %H:%M:%S')
SCRIPT_VERSION=$SCRIPT_VERSION
DOMAIN=$MEDIA_DOMAIN
USER=$UPLOAD_USER
UPLOAD_DIR=$UPLOAD_DIR_HOST
DOCKER_DIR=$DOCKER_DIR
EXTERNAL_PORT=$PORT_TO_USE
EOF
chmod 644 "$MARKER_FILE"

# === ИТОГ ===
log_step "✅ Готово!"
echo "🔗 https://$MEDIA_DOMAIN/test_keymaster.txt"
echo "⚠️ Cloudflare: A-запись $MEDIA_DOMAIN -> IP, Proxy OFF (серое), SSL Full Strict"
