#!/bin/bash

# KeyMaster Server Setup Script
# Настройка веб-сервера и SFTP для загрузки файлов в OpenAI

set -e

# === Цвета для вывода ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# === Логирование ===
log_info()    { echo -e "${BLUE}[ℹ️]${NC} $1"; }
log_success() { echo -e "${GREEN}[✅]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[⚠️]${NC} $1"; }
log_error()   { echo -e "${RED}[❌]${NC} $1"; }

# === Проверка прав ===
if [[ $EUID -ne 0 ]]; then
   log_error "Скрипт должен быть запущен от имени root"
   exit 1
fi

echo -e "\n┌─────────────────────────────────┐"
echo -e "│  KeyMaster Server Setup ${GREEN}v1.0${NC}  │"
echo -e "└─────────────────────────────────┘\n"

# === 1. Домен ===
read -p "🌐 Введите домен для загрузки (например: media.norest.art): " DOMAIN
DOMAIN=$(echo "$DOMAIN" | sed 's|https\?://||; s|/$||')
if [[ -z "$DOMAIN" ]]; then
    log_error "Домен не может быть пустым"
    exit 1
fi
log_info "Домен: ${GREEN}$DOMAIN${NC}"

# === 2. Пользователь ===
read -p "👤 Введите имя пользователя для загрузки [keymaster]: " USERNAME
USERNAME=${USERNAME:-keymaster}
log_info "Пользователь: ${GREEN}$USERNAME${NC}"

# === 3. SSH публичный ключ ===
echo -e "\n🔑 Введите публичный ключ SSH (формат: ssh-rsa AAAA... comment)"
echo -e "   ${YELLOW}Нажмите Enter после вставки ключа:${NC}"
read -r SSH_PUBLIC_KEY

if [[ -z "$SSH_PUBLIC_KEY" ]]; then
    log_error "SSH ключ не может быть пустым"
    exit 1
fi
log_info "SSH ключ принят"

# === 4. Параметры ===
SSH_PORT=6934
UPLOAD_DIR="/var/www/uploads"
WEB_ROOT="/var/www/html"

# === 5. Создание пользователя ===
if id "$USERNAME" &>/dev/null; then
    log_warn "Пользователь $USERNAME уже существует, пропускаем создание"
else
    log_info "Создаём пользователя $USERNAME..."
    useradd -m -s /usr/sbin/nologin "$USERNAME" 2>/dev/null || \
    useradd -m -s /bin/false "$USERNAME"
    log_success "Пользователь создан"
fi

# === 6. Настройка SSH ключа ===
log_info "Настраиваем SSH-доступ..."
SSH_DIR="/home/$USERNAME/.ssh"
mkdir -p "$SSH_DIR"
echo "$SSH_PUBLIC_KEY" > "$SSH_DIR/authorized_keys"
chmod 700 "$SSH_DIR"
chmod 600 "$SSH_DIR/authorized_keys"
chown -R "$USERNAME:$USERNAME" "$SSH_DIR"
log_success "SSH ключ установлен"

# === 7. Папки и права ===
log_info "Создаём директорию для загрузок: $UPLOAD_DIR"
mkdir -p "$UPLOAD_DIR"
chown -R "$USERNAME:$USERNAME" "$UPLOAD_DIR"
chmod 755 "$UPLOAD_DIR"

log_info "Создаём веб-корень: $WEB_ROOT"
mkdir -p "$WEB_ROOT"
chmod 755 "$WEB_ROOT"

# === 8. Настройка SSHD ===
log_info "Настраиваем SSH-сервер (порт $SSH_PORT)..."

# Резервная копия конфига
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%s)

# Добавляем конфигурацию для SFTP
cat >> /etc/ssh/sshd_config << EOF

# KeyMaster SFTP Config
Port $SSH_PORT
Match User $USERNAME
    ForceCommand internal-sftp
    ChrootDirectory $WEB_ROOT
    PermitTunnel no
    AllowAgentForwarding no
    AllowTcpForwarding no
    X11Forwarding no
EOF

# Проверка конфига и перезапуск
if sshd -t; then
    log_success "Конфигурация SSH валидна"
    if command -v systemctl &>/dev/null; then
        systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || true
    else
        service ssh restart 2>/dev/null || true
    fi
    log_success "SSH перезагружен"
else
    log_error "Ошибка в конфигурации SSH! Восстановлен бэкап."
    mv /etc/ssh/sshd_config.bak.* /etc/ssh/sshd_config
    exit 1
fi

# === 9. Настройка Nginx ===
log_info "Устанавливаем и настраиваем Nginx..."

if ! command -v nginx &>/dev/null; then
    if [[ -f /etc/debian_version ]]; then
        apt update -qq && apt install -y nginx > /dev/null 2>&1
    elif [[ -f /etc/redhat-release ]]; then
        yum install -y epel-release > /dev/null 2>&1
        yum install -y nginx > /dev/null 2>&1
    else
        log_warn "Не удалось автоматически установить nginx. Установите его вручную."
    fi
fi

# Конфиг сайта
NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

cat > "$NGINX_CONF" << EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN www.$DOMAIN;

    root $WEB_ROOT;
    index index.html;

    # Разрешаем только изображения и видео для OpenAI
    location ~* \.(jpg|jpeg|png|gif|webp|mp4|avi|mov|mkv|wmv)$ {
        add_header Access-Control-Allow-Origin *;
        add_header Cache-Control "public, immutable, max-age=31536000";
        try_files \$uri =404;
    }

    # Блокируем всё остальное
    location / {
        return 403;
    }

    # Логирование
    access_log /var/log/nginx/${DOMAIN}_access.log;
    error_log /var/log/nginx/${DOMAIN}_error.log;
}
EOF

# Создаём симлинк если нужно
[[ -L /etc/nginx/sites-enabled/$DOMAIN ]] || ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/

# Проверка и перезапуск nginx
if nginx -t 2>/dev/null; then
    if command -v systemctl &>/dev/null; then
        systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
    else
        service nginx reload 2>/dev/null || service nginx restart 2>/dev/null || true
    fi
    log_success "Nginx настроен и перезапущен"
else
    log_warn "Ошибка в конфиге nginx — проверьте вручную: nginx -t"
fi

# === 10. Let's Encrypt (опционально) ===
log_info "💡 Для HTTPS установите certbot:"
echo -e "   ${YELLOW}certbot --nginx -d $DOMAIN -d www.$DOMAIN${NC}"
echo -e "   После установки обновите конфиг: listen 443 ssl + пути к сертификатам"

# === 11. Финальная настройка прав ===
# Создаём симлинк uploads -> веб-корень для удобства
if [[ ! -L "$WEB_ROOT/uploads" && "$UPLOAD_DIR" != "$WEB_ROOT/uploads" ]]; then
    ln -sf "$UPLOAD_DIR" "$WEB_ROOT/uploads"
    chown -R "$USERNAME:$USERNAME" "$WEB_ROOT/uploads"
fi

# === 12. Итоговый вывод ===
echo -e "\n${GREEN}╔════════════════════════════════════╗${NC}"
echo -e "${GREEN}║${NC}  ${BLUE}✅ Настройка завершена успешно!${NC}  ${GREEN}║${NC}"
echo -e "${GREEN}╚════════════════════════════════════╝${NC}\n"

echo -e "${YELLOW}📋 Параметры для вашего Python-скрипта:${NC}"
echo -e "   server_ip        = \"$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')\""
echo -e "   server_port      = $SSH_PORT"
echo -e "   username         = \"$USERNAME\""
echo -e "   private_key_path = \"uploadkey.pem\"  ${BLUE}# ваш приватный ключ${NC}"
echo -e "   remote_folder    = \"/uploads\"       ${BLUE}# относительно ChrootDirectory${NC}"
echo -e "   media_domain     = \"https://$DOMAIN\"${NC}"

echo -e "\n${YELLOW}🔗 Публичный доступ к файлам:${NC}"
echo -e "   https://$DOMAIN/filename.jpg"

echo -e "\n${YELLOW}📁 Директории:${NC}"
echo -e "   Загрузка (SFTP): $UPLOAD_DIR"
echo -e "   Веб-доступ:      $WEB_ROOT"
echo -e "   Chroot для $USERNAME: $WEB_ROOT"

echo -e "\n${YELLOW}🔐 SSH-подключение для загрузки:${NC}"
echo -e "   sftp -P $SSH_PORT -i uploadkey.pem $USERNAME@$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
echo -e "   ${BLUE}# Файлы загружать в папку /uploads/${NC}"

echo -e "\n${YELLOW}⚙️  Если файлы не доступны — проверьте:${NC}"
echo -e "   1. SELinux: ${BLUE}setsebool -P httpd_unified 1${NC} (если включён)"
echo -e "   2. Firewall: ${BLUE}ufw allow 80/tcp${NC} и ${BLUE}ufw allow $SSH_PORT/tcp${NC}"
echo -e "   3. Права: ${BLUE}ls -la $WEB_ROOT${NC}"

echo -e "\n${GREEN}🚀 Готово! Запускайте ваш Python-скрипт.${NC}\n"
