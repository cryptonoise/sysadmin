#!/bin/bash
# Запуск: curl -fsSL https://raw.githubusercontent.com/cryptonoise/sysadmin/refs/heads/main/server4keymaster.sh | bash

# === ВЕРСИЯ СКРИПТА ===
SCRIPT_VERSION="v5.2-FixCertbotArgs"
SCRIPT_NAME="KeyMaster Server (Safe Mode)"
# === МЕТКА УСТАНОВКИ ===
MARKER_FILE="/etc/keymaster-server-setup.marker"
UPLOAD_DIR_HOST="/var/www/keymaster-media"
HTTPS_PORT=4443 # <-- Нестандартный порт для HTTPS
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
log_step()    { echo -e "\n${CYAN}────────────────────────────────${NC}\n${CYAN}[ ⚙️ ]${NC} $1\n${CYAN}────────────────────────────────${NC}\n"; }
log_detail()  { echo -e "   ${CYAN}→${NC} $1"; }

# === ФУНКЦИЯ ПАУЗЫ И ПОДТВЕРЖДЕНИЯ ===
pause_script() {
    local message="$1"
    local critical="${2:-false}" # Если true, то по умолчанию 'Нет' (безопаснее)
    
    echo ""
    log_warn "$message"
    echo ""
    
    if [[ "$critical" == "true" ]]; then
        read -p "❓ Хотите продолжить? (y/N): " confirm < /dev/tty
    else
        read -p "❓ Хотите продолжить? (Y/n): " confirm < /dev/tty
    fi
    
    # Приводим к нижнему регистру
    confirm=$(echo "$confirm" | tr '[:upper:]' '[:lower:]')
    
    # Если критично и пустой ввод -> считаем как Нет. Если не критично и пустой -> считаем как Да.
    if [[ "$critical" == "true" ]]; then
        if [[ "$confirm" != "y" && "$confirm" != "yes" ]]; then
            log_error "Операция прервана пользователем."
            exit 1
        fi
    else
        if [[ "$confirm" == "n" || "$confirm" == "no" ]]; then
            log_error "Операция прервана пользователем."
            exit 1
        fi
    fi
    echo ""
}

# === ЗАГОЛОВОК ===
print_header() {
    echo ""
    echo -e "${RED}────────────────────────────────${NC}"
    echo -e "  ${GREEN}${SCRIPT_NAME}${NC}"
    echo -e "  Версия: ${CYAN}${SCRIPT_VERSION}${NC}"
    echo -e "  HTTPS Port: ${MAGENTA}${HTTPS_PORT}${NC}"
    echo -e "${RED}────────────────────────────────${NC}"
    echo ""
}

print_header

# Проверка root
if [[ $EUID -ne 0 ]]; then
    log_error "Скрипт должен быть запущен от имени root"
    exit 1
fi

# === ПРОВЕРКА МЕТКИ ===
if [[ -f "$MARKER_FILE" ]]; then
    log_warn "Обнаружена метка предыдущей установки"
    echo "📋 Скрипт уже запускался на этом сервере."
    echo "   Домен: $(grep '^DOMAIN=' "$MARKER_FILE" | cut -d'=' -f2)"
    echo "   Пользователь: $(grep '^USER=' "$MARKER_FILE" | cut -d'=' -f2)"
    echo ""
    echo -e "${YELLOW}Выберите действие:${NC}"
    echo "   1 - Продолжить настройку (обновить конфиги/SSL)"
    echo "   2 - 🗑️  ОТКАТИТЬ все изменения (удалить сайт, юзера, сертификаты)"
    echo "   3 - Выйти"
    read -p "Введите номер [1-3]: " ACTION_CHOICE < /dev/tty
    
    case $ACTION_CHOICE in
        2)
            pause_script "Вы уверены, что хотите полностью удалить KeyMaster и все связанные данные?" "true"
            
            log_step "🗑️  Откат"
            PREV_USER=$(grep '^USER=' "$MARKER_FILE" | cut -d'=' -f2)
            PREV_DOMAIN=$(grep '^DOMAIN=' "$MARKER_FILE" | cut -d'=' -f2)
            
            # Удаляем конфиг nginx (имя файла = домен.conf)
            rm -f "/etc/nginx/sites-available/${PREV_DOMAIN}.conf"
            rm -f "/etc/nginx/sites-enabled/${PREV_DOMAIN}.conf"
            
            # Удаляем папку файлов
            [[ -d "$UPLOAD_DIR_HOST" ]] && { log_detail "Удаление папки: $UPLOAD_DIR_HOST"; rm -rf "$UPLOAD_DIR_HOST"; }
            
            # Удаляем пользователя
            if [[ -n "$PREV_USER" ]] && id "$PREV_USER" &>/dev/null; then
                log_detail "Удаление пользователя: $PREV_USER"
                userdel -r "$PREV_USER" 2>/dev/null || true
            fi
            
            # Удаляем сертификат
            if [[ -d "/etc/letsencrypt/live/$PREV_DOMAIN" ]]; then
                log_detail "Удаление сертификата: $PREV_DOMAIN"
                certbot delete --cert-name "$PREV_DOMAIN" --non-interactive || true
            fi
            
            nginx -t && systemctl reload nginx 2>/dev/null || true
            rm -f "$MARKER_FILE"
            echo -e "${GREEN}✅ Откат завершён${NC}"; exit 0
            ;;
        3) exit 0 ;;
        1) log_info "Продолжение настройки..." ;;
        *) log_error "Неверный выбор"; exit 1 ;;
    esac
fi

[[ ! -f /etc/os-release ]] && { log_error "Не удалось определить ОС"; exit 1; }
source /etc/os-release
OS_ID=$ID
log_info "ОС: $PRETTY_NAME"

# === ШАГ 1: Домен ===
log_step "Шаг 1: Настройка домена"
while true; do
    read -p "🌐 Введите домен: " MEDIA_DOMAIN < /dev/tty
    MEDIA_DOMAIN=$(echo "$MEDIA_DOMAIN" | xargs | sed 's|https\?://||' | sed 's|/$||')
    [[ -z "$MEDIA_DOMAIN" ]] && { log_error "Домен не может быть пустым"; continue; }
    [[ ! "$MEDIA_DOMAIN" =~ \. ]] && { log_error "Домен должен содержать точку"; continue; }
    [[ ! "$MEDIA_DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]] && { log_error "Недопустимые символы"; continue; }
    break
done
log_success "Домен: $MEDIA_DOMAIN"

# Имя конфига Nginx будет таким же, как домен
NGINX_CONF_NAME="${MEDIA_DOMAIN}.conf"
MAIN_CONF="/etc/nginx/sites-available/${NGINX_CONF_NAME}"

# === ШАГ 2: Пользователь SFTP ===
log_step "Шаг 2: Пользователь для SFTP"
read -p "👤 Имя пользователя для загрузки файлов [keymaster]: " UPLOAD_USER < /dev/tty
UPLOAD_USER=${UPLOAD_USER:-keymaster}
[[ -z "$UPLOAD_USER" ]] && { log_error "Имя не может быть пустым"; exit 1; }

if id "$UPLOAD_USER" &>/dev/null; then
    pause_script "Пользователь '$UPLOAD_USER' уже существует. Его SSH ключи будут перезаписаны. Продолжить?" "true"
else
    log_detail "Создание пользователя: $UPLOAD_USER"
    useradd -m -s /bin/bash "$UPLOAD_USER"
    log_success "Пользователь создан"
fi
log_success "Пользователь: $UPLOAD_USER"

# === ШАГ 3: SSH Ключ ===
log_step "Шаг 3: SSH Публичный Ключ"
echo "🔑 Вставьте публичный SSH ключ (содержимое id_rsa.pub):"
echo "   (Нажмите Enter после вставки)"
read -r SSH_PUBLIC_KEY < /dev/tty

if [[ -z "$SSH_PUBLIC_KEY" ]]; then
    log_error "Ключ не может быть пустым"
    exit 1
fi

# Настройка .ssh директории
SSH_DIR="/home/$UPLOAD_USER/.ssh"
mkdir -p "$SSH_DIR"
echo "$SSH_PUBLIC_KEY" > "$SSH_DIR/authorized_keys"
chmod 700 "$SSH_DIR"
chmod 600 "$SSH_DIR/authorized_keys"
chown -R "$UPLOAD_USER:$UPLOAD_USER" "$SSH_DIR"
log_success "SSH ключ установлен для пользователя $UPLOAD_USER"
log_info "Подключение по SFTP: sftp $UPLOAD_USER@YOUR_SERVER_IP"

# === ШАГ 4: Установка Nginx и Certbot ===
log_step "Шаг 4: Проверка Nginx и Certbot"
install_deps() {
    case $OS_ID in
        ubuntu|debian)
            apt-get update
            apt-get install -y nginx certbot python3-certbot-nginx curl ufw
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
    log_success "Nginx уже установлен"
fi

if ! command -v certbot &>/dev/null; then
    log_warn "Certbot не найден. Устанавливаем..."
    install_deps
    log_success "Certbot установлен"
fi

# === ПРОВЕРКА КОНФЛИКТОВ ПОРТОВ ===
log_step "Проверка конфликтов портов"
CONFLICT_FOUND=false

# Проверяем порт 80
PORT_80_INFO=$(ss -tlnp | grep ":80 " || true)
if [[ -n "$PORT_80_INFO" ]]; then
    log_warn "Порт 80 занят."
    echo -e "   ${YELLOW}Кем занят:${NC} $PORT_80_INFO"
    echo ""
    log_detail "Для получения SSL-сертификата скрипт использует режим 'Standalone'."
    log_detail "Это означает, что Nginx будет ВРЕМЕННО остановлен."
    log_detail "После получения сертификата Nginx будет автоматически запущен обратно."
    CONFLICT_FOUND=true
fi

# Проверяем порт 4443 (наш целевой)
if ss -tlnp | grep ":${HTTPS_PORT} " &>/dev/null; then
    log_error "Порт ${HTTPS_PORT} уже занят другим процессом!"
    ss -tlnp | grep ":${HTTPS_PORT} "
    pause_script "Освободите порт ${HTTPS_PORT} перед запуском скрипта." "true"
fi

if [[ "$CONFLICT_FOUND" == "true" ]]; then
    pause_script "Если вы согласны с временной остановкой Nginx, продолжите." "false"
fi

# === ШАГ 5: Получение SSL Сертификата (Standalone Mode) ===
log_step "Шаг 5: SSL Сертификат"

CERT_PATH="/etc/letsencrypt/live/$MEDIA_DOMAIN/fullchain.pem"

if [[ -f "$CERT_PATH" ]]; then
    log_info "Сертификат для $MEDIA_DOMAIN уже существует. Проверяем валидность..."
    CERT_CN=$(openssl x509 -in "$CERT_PATH" -noout -subject 2>/dev/null | sed -n 's/.*CN = \(.*\)/\1/p')
    if [[ "$CERT_CN" != "$MEDIA_DOMAIN" ]]; then
        pause_script "Сертификат выдан для '$CERT_CN', а не для '$MEDIA_DOMAIN'. Он будет удален и получен заново. Продолжить?" "true"
        rm -rf "/etc/letsencrypt/live/$MEDIA_DOMAIN"
        rm -rf "/etc/letsencrypt/archive/$MEDIA_DOMAIN"
        rm -rf "/etc/letsencrypt/renewal/$MEDIA_DOMAIN.conf"
        GET_NEW_CERT=true
    else
        log_success "Сертификат валиден."
        GET_NEW_CERT=false
    fi
else
    GET_NEW_CERT=true
fi

if [[ "$GET_NEW_CERT" == "true" ]]; then
    log_detail "Останавливаем Nginx для получения сертификата (Standalone mode)..."
    systemctl stop nginx
    
    log_detail "Запрос сертификата для $MEDIA_DOMAIN..."
    # Исправлено: убран неверный флаг --keep-until-expanding
    # Добавлен --http-01-port 80 для явности
    certbot certonly --standalone --http-01-port 80 -d "$MEDIA_DOMAIN" --non-interactive --agree-tos -m admin@"$MEDIA_DOMAIN" --keep-until-expiring --expand
    
    if [[ $? -eq 0 ]]; then
        log_success "Сертификат успешно получен!"
    else
        log_error "Ошибка получения сертификата. Проверьте DNS A-запись для $MEDIA_DOMAIN"
        systemctl start nginx
        pause_script "Не удалось получить сертификат. Нажмите Enter для выхода." "true"
        exit 1
    fi
    
    log_detail "Запускаем Nginx обратно..."
    systemctl start nginx
fi

# === ШАГ 6: Подготовка папок ===
log_step "Шаг 6: Папки и права"
if [[ -d "$UPLOAD_DIR_HOST" ]]; then
    pause_script "Папка $UPLOAD_DIR_HOST уже существует. Она будет очищена и пересоздана. Продолжить?" "true"
    rm -rf "$UPLOAD_DIR_HOST"
fi

mkdir -p "$UPLOAD_DIR_HOST"

# Владелец - наш SFTP пользователь, группа www-data (для чтения Nginx)
chown -R "$UPLOAD_USER:www-data" "$UPLOAD_DIR_HOST"
chmod 750 "$UPLOAD_DIR_HOST"

echo "<h1>KeyMaster Native + SFTP Ready</h1><p>Upload files via SFTP to $UPLOAD_DIR_HOST</p>" > "$UPLOAD_DIR_HOST/index.html"
chown "$UPLOAD_USER:www-data" "$UPLOAD_DIR_HOST/index.html"
chmod 640 "$UPLOAD_DIR_HOST/index.html"

log_success "Папка создана: $UPLOAD_DIR_HOST"
log_detail "Владелец: $UPLOAD_USER"
log_detail "Группа: www-data"

# === ШАГ 7: Основной конфиг Nginx (HTTPS на порту 4443) ===
log_step "Шаг 7: Конфиг Nginx (HTTPS :${HTTPS_PORT})"
log_detail "Имя файла конфига: $NGINX_CONF_NAME"

if [[ -f "$MAIN_CONF" ]]; then
    pause_script "Конфиг Nginx $MAIN_CONF уже существует. Он будет перезаписан. Продолжить?" "true"
fi

cat > "$MAIN_CONF" << EOF
server {
    listen 80;
    server_name $MEDIA_DOMAIN www.$MEDIA_DOMAIN;
    # Редирект на HTTPS с явным указанием порта
    return 301 https://\$host:${HTTPS_PORT}\$request_uri;
}

server {
    listen ${HTTPS_PORT} ssl http2;
    server_name $MEDIA_DOMAIN www.$MEDIA_DOMAIN;

    # Пути к сертификатам (строго для этого домена)
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
    root $UPLOAD_DIR_HOST;
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
    pause_script "Ошибка в конфиге Nginx. Нажмите Enter для выхода и ручной проверки." "true"
    exit 1
fi

# === ШАГ 7.5: Настройка Firewall (UFW) ===
log_step "Шаг 7.5: Настройка Firewall"
if command -v ufw &>/dev/null; then
    if ufw status | grep -q "Status: active"; then
        log_detail "UFW активен. Открываем порт ${HTTPS_PORT}..."
        ufw allow ${HTTPS_PORT}/tcp
        ufw reload
        log_success "Порт ${HTTPS_PORT} открыт в firewall"
    else
        log_info "UFW не активен. Пропускаем настройку правил."
    fi
else
    log_info "UFW не установлен. Убедитесь, что порт ${HTTPS_PORT} открыт в панели вашего хостинга/облака."
fi

# === ШАГ 8: Тестовый файл ===
log_step "Шаг 8: Создание тестового файла"
TEST_FILE="$UPLOAD_DIR_HOST/test_keymaster.txt"
echo "KeyMaster server is ready! $(date)" > "$TEST_FILE"
chown "$UPLOAD_USER:www-data" "$TEST_FILE"
chmod 640 "$TEST_FILE"
log_success "✅ Файл создан: $TEST_FILE"

# === ШАГ 9: Метка ===
log_step "Шаг 9: Метка установки"
cat > "$MARKER_FILE" << EOF
INSTALLED_AT=$(date '+%Y-%m-%d %H:%M:%S')
SCRIPT_VERSION=$SCRIPT_VERSION
DOMAIN=$MEDIA_DOMAIN
USER=$UPLOAD_USER
UPLOAD_DIR=$UPLOAD_DIR_HOST
NGINX_CONF=$NGINX_CONF_NAME
HTTPS_PORT=$HTTPS_PORT
EOF
chmod 644 "$MARKER_FILE"
log_success "✅ Метка создана"

# === ИТОГ ===
log_step "✅ Настройка завершена!"
echo -e "${RED}────────────────────────────────${NC}"
echo "🎉 Сервер KeyMaster готов к работе!"
echo -e "${RED}────────────────────────────────${NC}"
echo ""
echo "📋 Параметры:"
echo "   • Домен:            $MEDIA_DOMAIN"
echo "   • Пользователь SFTP:$UPLOAD_USER"
echo "   • Папка загрузок:   $UPLOAD_DIR_HOST"
echo "   • Конфиг Nginx:     $NGINX_CONF_NAME"
echo "   • HTTPS Порт:       ${HTTPS_PORT}"
echo ""
echo "🔐 SFTP Доступ:"
echo "   Host: YOUR_SERVER_IP"
echo "   User: $UPLOAD_USER"
echo "   Port: 22 (или ваш нестандартный SSH порт)"
echo "   Auth: Public Key"
echo ""
echo " Управление:"
echo "   • Логи Nginx:       tail -f /var/log/nginx/keymaster-access.log"
echo "   • Перезагрузка:     systemctl restart nginx"
echo ""
echo -e "${YELLOW}⚠️  Cloudflare / DNS:${NC}"
echo "   • A-запись: $MEDIA_DOMAIN -> Твой IP"
echo "   • Proxy Status: OFF (Серое облако) - обязательно для Standalone SSL!"
echo "   • SSL/TLS Mode: Full (Strict)"
echo ""
echo "🧪 Проверка:"
echo -e "   🔗 https://$MEDIA_DOMAIN:${HTTPS_PORT}/test_keymaster.txt"
echo ""
