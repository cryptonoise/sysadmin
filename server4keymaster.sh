#!/bin/bash
# server4keymaster.sh - Настройка сервера для KeyMaster
# Запуск: curl -fsSL https://raw.githubusercontent.com/cryptonoise/sysadmin/refs/heads/main/server4keymaster.sh | bash

# === ВЕРСИЯ СКРИПТА ===
SCRIPT_VERSION="v2.3"
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
    echo "   2 - 🗑️  ОТКАТИТЬ все изменения (удалить пользователя, конфиги, папки)"
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
            
            if id "$PREV_USER" &>/dev/null; then
                log_info "Удаление пользователя: $PREV_USER"
                userdel -r "$PREV_USER" 2>/dev/null || true
                log_success "Пользователь $PREV_USER удалён"
            else
                log_warn "Пользователь $PREV_USER не найден"
            fi
            
            if [[ -n "$PREV_UPLOAD_DIR" ]] && [[ -d "$PREV_UPLOAD_DIR" ]]; then
                log_info "Удаление папки: $PREV_UPLOAD_DIR"
                rm -rf "$PREV_UPLOAD_DIR"
                log_success "Папка $PREV_UPLOAD_DIR удалена"
            fi
            
            if [[ -n "$PREV_DOMAIN" ]]; then
                NGINX_CONF="/etc/nginx/sites-available/$PREV_DOMAIN"
                NGINX_LINK="/etc/nginx/sites-enabled/$PREV_DOMAIN"
                
                if [[ -f "$NGINX_CONF" ]]; then
                    rm -f "$NGINX_CONF"
                    log_success "Конфиг nginx удалён"
                fi
                
                if [[ -L "$NGINX_LINK" ]]; then
                    rm -f "$NGINX_LINK"
                    log_success "Симлинк nginx удалён"
                fi
                
                systemctl reload nginx 2>/dev/null || true
            fi
            
            SSH_CONFIG="/etc/ssh/sshd_config"
            if grep -q "^Port $PREV_SSH_PORT" "$SSH_CONFIG" 2>/dev/null; then
                sed -i "/^Port $PREV_SSH_PORT/d" "$SSH_CONFIG"
                systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
                log_success "Порт $PREV_SSH_PORT удалён из SSH"
            fi
            
            if command -v ufw &> /dev/null; then
                ufw delete allow $PREV_SSH_PORT/tcp 2>/dev/null || true
                ufw delete allow 80/tcp 2>/dev/null || true
                ufw delete allow 443/tcp 2>/dev/null || true
                log_success "Правила UFW удалены"
            elif command -v firewall-cmd &> /dev/null; then
                firewall-cmd --permanent --remove-port=$PREV_SSH_PORT/tcp 2>/dev/null || true
                firewall-cmd --permanent --remove-service=http 2>/dev/null || true
                firewall-cmd --permanent --remove-service=https 2>/dev/null || true
                firewall-cmd --reload 2>/dev/null || true
                log_success "Правила firewalld удалены"
            fi
            
            if [[ -n "$PREV_DOMAIN" ]]; then
                rm -f /var/log/nginx/${PREV_DOMAIN}_access.log 2>/dev/null || true
                rm -f /var/log/nginx/${PREV_DOMAIN}_error.log 2>/dev/null || true
            fi
            
            rm -f "$MARKER_FILE"
            
            echo ""
            echo -e "${GREEN}╔════════════════════════════════════════════════════╗${NC}"
            echo -e "${GREEN}║  ✅ Откат завершён успешно!                        ║${NC}"
            echo -e "${GREEN}╚════════════════════════════════════════════════════╝${NC}"
            echo ""
            log_info "Сервер возвращён в исходное состояние"
            exit 0
            ;;
        3)
            log_warn "Выход без изменений"
            exit 0
            ;;
        1)
            log_info "Продолжение настройки (обновление конфигурации)"
            ;;
        *)
            log_error "Неверный выбор"
            exit 1
            ;;
    esac
fi

if [[ ! -f /etc/os-release ]]; then
    log_error "Не удалось определить ОС. Скрипт поддерживает только Linux"
    exit 1
fi

source /etc/os-release
OS_ID=$ID

log_info "Обнаружена ОС: $PRETTY_NAME"

# === ШАГ 1: Ввод домена ===
log_step "Шаг 1: Настройка домена"

while true; do
    read -p "🌐 Введите домен для загрузки файлов: " MEDIA_DOMAIN < /dev/tty
    MEDIA_DOMAIN=$(echo "$MEDIA_DOMAIN" | xargs | sed 's|https\?://||' | sed 's|/$||')
    
    if [[ -z "$MEDIA_DOMAIN" ]]; then
        log_error "Домен не может быть пустым. Попробуйте снова."
        continue
    fi
    
    if [[ ! "$MEDIA_DOMAIN" =~ \. ]]; then
        log_error "Неверный формат домена. Домен должен содержать точку."
        continue
    fi
    
    if [[ ! "$MEDIA_DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]]; then
        log_error "Домен содержит недопустимые символы."
        continue
    fi
    
    break
done

log_success "Домен: $MEDIA_DOMAIN"

# === ШАГ 2: Ввод пользователя ===
log_step "Шаг 2: Пользователь для загрузки"
read -p "👤 Введите имя пользователя для загрузки [по-умолачнию keymaster]: " UPLOAD_USER < /dev/tty
UPLOAD_USER=${UPLOAD_USER:-keymaster}
UPLOAD_USER=$(echo "$UPLOAD_USER" | xargs)

if [[ -z "$UPLOAD_USER" ]]; then
    log_error "Имя пользователя не может быть пустым"
    exit 1
fi
log_success "Пользователь: $UPLOAD_USER"

# === ШАГ 3: Ввод SSH публичного ключа ===
log_step "Шаг 3: Настройка SSH-ключа"
echo "🔑 Введите публичный SSH-ключ для пользователя $UPLOAD_USER"
echo "   Формат: ssh-rsa AAAAB3... или ssh-ed25519 AAAAC3..."
read -r SSH_PUBLIC_KEY < /dev/tty

if [[ -z "$SSH_PUBLIC_KEY" ]]; then
    log_error "SSH ключ не может быть пустым"
    exit 1
fi
log_success "SSH-ключ принят"

# === ШАГ 4: Ввод SSH порта ===
log_step "Шаг 4: Настройка SSH-порта"
read -p "🔌 Введите порт для SSH-подключения [по-умолачнию 6934]: " SSH_PORT < /dev/tty
SSH_PORT=${SSH_PORT:-6934}

if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [[ "$SSH_PORT" -lt 1 ]] || [[ "$SSH_PORT" -gt 65535 ]]; then
    log_error "Неверный номер порта. Должен быть от 1 до 65535"
    exit 1
fi

if [[ "$SSH_PORT" == "22" ]]; then
    log_warn "Порт 22 — стандартный SSH порт."
fi

log_success "SSH порт: $SSH_PORT"

# === ШАГ 5: Установка зависимостей ===
log_step "Шаг 5: Установка необходимых пакетов"
log_info "Запускаем обновление репозиториев и установку пакетов..."

case $OS_ID in
    ubuntu|debian)
        apt-get update -qq
        apt-get install -y -qq nginx openssh-server curl wget ufw certbot python3-certbot-nginx
        ;;
    centos|rhel|fedora|almalinux|rocky)
        if command -v dnf &> /dev/null; then
            dnf install -y -q nginx openssh-server curl wget firewalld certbot
        else
            yum install -y -q nginx openssh-server curl wget firewalld certbot
        fi
        ;;
    *)
        log_error "Неизвестная ОС: $OS_ID"
        exit 1
        ;;
esac

log_success "Пакеты установлены"

# === ШАГ 6: Создание пользователя ===
log_step "Шаг 6: Создание пользователя $UPLOAD_USER"
if id "$UPLOAD_USER" &>/dev/null; then
    log_warn "Пользователь уже существует"
else
    useradd -m -s /bin/bash -G www-data "$UPLOAD_USER" 2>/dev/null || useradd -m -s /bin/bash "$UPLOAD_USER"
    log_success "Пользователь $UPLOAD_USER создан"
fi

# === ШАГ 7: Настройка SSH ключа ===
log_step "Шаг 7: Настройка SSH-доступа"
SSH_DIR="/home/$UPLOAD_USER/.ssh"
mkdir -p "$SSH_DIR"
echo "$SSH_PUBLIC_KEY" > "$SSH_DIR/authorized_keys"
chmod 700 "$SSH_DIR"
chmod 600 "$SSH_DIR/authorized_keys"
chown -R "$UPLOAD_USER:$UPLOAD_USER" "$SSH_DIR"
log_success "SSH-ключ настроен"

SSH_CONFIG="/etc/ssh/sshd_config"
if ! grep -q "^Port $SSH_PORT" "$SSH_CONFIG" 2>/dev/null; then
    sed -i "/^#Port 22/a Port $SSH_PORT" "$SSH_CONFIG" 2>/dev/null || echo "Port $SSH_PORT" >> "$SSH_CONFIG"
    log_success "Порт $SSH_PORT добавлен в SSH"
fi

systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
log_success "SSH-сервис перезапущен"

# === ШАГ 8: Настройка папки для загрузок ===
log_step "Шаг 8: Создание папки для загрузок"
UPLOAD_DIR="/var/www/uploads"
mkdir -p "$UPLOAD_DIR"
chown -R "$UPLOAD_USER:www-data" "$UPLOAD_DIR"
chmod 755 "$UPLOAD_DIR"
log_success "Папка $UPLOAD_DIR готова"

# === ШАГ 9: Создание базового nginx конфига (HTTP) ===
log_step "Шаг 9: Настройка nginx (HTTP)"
NGINX_CONF="/etc/nginx/sites-available/$MEDIA_DOMAIN"
NGINX_LINK="/etc/nginx/sites-enabled/$MEDIA_DOMAIN"

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
            image/jpeg jpg jpeg;
            image/png png;
            image/webp webp;
            video/mp4 mp4;
            video/quicktime mov;
            video/x-msvideo avi;
            video/x-matroska mkv;
            video/x-ms-wmv wmv;
        }
        default_type application/octet-stream;
    }

    location ~ /\. {
        deny all;
        return 404;
    }

    access_log /var/log/nginx/${MEDIA_DOMAIN}_access.log;
    error_log /var/log/nginx/${MEDIA_DOMAIN}_error.log;
}
EOF

if [[ ! -L "$NGINX_LINK" ]] && [[ ! -f "$NGINX_LINK" ]]; then
    ln -s "$NGINX_CONF" "$NGINX_LINK"
fi

nginx -t
systemctl enable nginx
systemctl restart nginx
log_success "nginx запущен (порт 80)"

# === ШАГ 10: Получение SSL-сертификата ===
log_step "Шаг 10: Получение SSL-сертификата (Let's Encrypt)"
SKIP_CERTBOT=false

if ! curl -s --connect-timeout 5 "http://$MEDIA_DOMAIN" > /dev/null 2>&1; then
    log_warn "Не удалось подключиться к $MEDIA_DOMAIN по HTTP"
    read -p "Продолжить попытку получения сертификата? [y/N]: " CERTBOT_CONTINUE < /dev/tty
    if [[ "$CERTBOT_CONTINUE" != "y" ]] && [[ "$CERTBOT_CONTINUE" != "Y" ]]; then
        SKIP_CERTBOT=true
    fi
fi

if [[ "$SKIP_CERTBOT" == "false" ]]; then
    if certbot --nginx -d "$MEDIA_DOMAIN" -d "www.$MEDIA_DOMAIN" --non-interactive --agree-tos --redirect --email "admin@$MEDIA_DOMAIN" 2>/dev/null; then
        log_success "SSL-сертификат получен!"
    else
        log_error "Не удалось получить сертификат"
        SKIP_CERTBOT=true
    fi
fi

# === ШАГ 11: Настройка автообновления ===
log_step "Шаг 11: Настройка автообновления сертификата"

if systemctl list-unit-files | grep -q certbot.timer; then
    systemctl enable certbot.timer 2>/dev/null || true
    systemctl start certbot.timer 2>/dev/null || true
fi

if certbot renew --dry-run 2>&1 | grep -q "Congratulations"; then
    log_success "✅ Автообновление работает!"
else
    log_warn "⚠️  Проверка автообновления завершилась с предупреждениями"
fi

# === ШАГ 12: Обновление nginx для HTTPS (если сертификат получен) ===
if [[ "$SKIP_CERTBOT" == "false" ]]; then
    log_step "Шаг 12: Обновление nginx + Cloudflare Full (strict)"
    
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
            image/jpeg jpg jpeg;
            image/png png;
            image/webp webp;
            video/mp4 mp4;
            video/quicktime mov;
            video/x-msvideo avi;
            video/x-matroska mkv;
            video/x-ms-wmv wmv;
        }
        default_type application/octet-stream;
        
        add_header X-Content-Type-Options nosniff;
        add_header X-Frame-Options SAMEORIGIN;
    }

    location ~ /\. {
        deny all;
        return 404;
    }

    access_log /var/log/nginx/${MEDIA_DOMAIN}_access.log;
    error_log /var/log/nginx/${MEDIA_DOMAIN}_error.log;
}
EOF

    nginx -t
    systemctl reload nginx
    log_success "nginx перезапущен с HTTPS"
fi

# === ШАГ 13: Настройка фаервола ===
log_step "Шаг 13: Настройка фаервола"
if command -v ufw &> /dev/null; then
    ufw allow 22/tcp 2>/dev/null || true
    ufw allow $SSH_PORT/tcp 2>/dev/null || true
    ufw allow 80/tcp 2>/dev/null || true
    ufw allow 443/tcp 2>/dev/null || true
    echo "y" | ufw enable 2>/dev/null || true
    log_success "Правила UFW применены"
elif command -v firewall-cmd &> /dev/null; then
    firewall-cmd --permanent --add-service=ssh 2>/dev/null || true
    firewall-cmd --permanent --add-port=$SSH_PORT/tcp 2>/dev/null || true
    firewall-cmd --permanent --add-service=http 2>/dev/null || true
    firewall-cmd --permanent --add-service=https 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
    log_success "Правила firewalld применены"
else
    log_warn "Фаервол не обнаружен"
fi

# === ШАГ 14: Финальная настройка прав ===
log_step "Шаг 14: Настройка прав доступа"
chmod 755 "$UPLOAD_DIR"
chown -R "$UPLOAD_USER:www-data" "$UPLOAD_DIR"
find "$UPLOAD_DIR" -type f -exec chmod 644 {} \; 2>/dev/null || true
find "$UPLOAD_DIR" -type d -exec chmod 755 {} \; 2>/dev/null || true
log_success "Права доступа настроены"

# === ШАГ 15: Тестовый файл ===
log_step "Шаг 15: Создание тестового файла"
TEST_FILE="$UPLOAD_DIR/test_keymaster.txt"
echo "KeyMaster server is ready! $(date)" > "$TEST_FILE"
chown "$UPLOAD_USER:www-data" "$TEST_FILE"
chmod 644 "$TEST_FILE"
log_success "Тестовый файл создан"

# === ШАГ 16: Создание метки ===
log_step "Шаг 16: Создание метки установки"
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

# === ШАГ 17: Итоговая информация ===
log_step "✅ Настройка завершена!"
echo "╔════════════════════════════════════════════════════╗"
echo "║  🎉 Сервер KeyMaster готов к работе!              ║"
echo "╚════════════════════════════════════════════════════╝"
echo ""
echo "📋 Параметры:"
echo "   • Домен:            $MEDIA_DOMAIN"
echo "   • Пользователь:     $UPLOAD_USER"
echo "   • SSH порт:         $SSH_PORT"
echo "   • Папка загрузок:   $UPLOAD_DIR"
if [[ "$SKIP_CERTBOT" == "false" ]]; then
    echo "   • Веб-доступ:       https://$MEDIA_DOMAIN/"
else
    echo "   • Веб-доступ:       http://$MEDIA_DOMAIN/"
fi
echo ""
echo ""
echo "🧪 Проверка:"
echo "   ssh -p $SSH_PORT $UPLOAD_USER@$(hostname -I | awk '{print $1}' | head -1)"
if [[ "$SKIP_CERTBOT" == "false" ]]; then
    echo "   curl -I https://$MEDIA_DOMAIN/test_keymaster.txt"
else
    echo "   curl -I http://$MEDIA_DOMAIN/test_keymaster.txt"
fi
echo ""
if [[ "$SKIP_CERTBOT" == "false" ]]; then
    echo "☁️  Cloudflare:"
    echo "   • SSL/TLS → Full (strict)"
    echo "   • DNS → A-запись → $(hostname -I | awk '{print $1}' | head -1)"
    echo ""
    echo "🔄 Автообновление: ✅ включено"
fi
echo ""
echo "🗑️ Откат: перезапустите скрипт → опция 2"
echo ""
log_success "Готово! 🚀"
echo ""
