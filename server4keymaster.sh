#!/bin/bash
# server4keymaster.sh - Настройка сервера для KeyMaster
# Запуск: curl -fsSL https://raw.githubusercontent.com/cryptonoise/sysadmin/refs/heads/main/server4keymaster.sh | bash

# === ВЕРСИЯ СКРИПТА ===
SCRIPT_VERSION="v1.2.0"
SCRIPT_NAME="KeyMaster Server Setup"

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

# === ЗАГОЛОВОК ПРИ ЗАПУСКЕ ===
print_header() {
    echo ""
    echo -e "${MAGENTA}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║${NC}  ${GREEN}${SCRIPT_NAME}${NC}                        ${MAGENTA}║${NC}"
    echo -e "${MAGENTA}║${NC}  Версия: ${CYAN}${SCRIPT_VERSION}${NC}                                  ${MAGENTA}║${NC}"
    echo -e "${MAGENTA}║${NC}  GitHub: cryptonoise/sysadmin                     ${MAGENTA}║${NC}"
    echo -e "${MAGENTA}╚════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BLUE}🚀 Инициализация...${NC}"
    echo ""
}

print_header

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
   log_error "Скрипт должен быть запущен от имени root"
   exit 1
fi

# Проверка ОС
if [[ ! -f /etc/os-release ]]; then
    log_error "Не удалось определить ОС. Скрипт поддерживает только Linux"
    exit 1
fi

source /etc/os-release
OS_ID=$ID

log_info "Обнаружена ОС: $PRETTY_NAME"

# === ШАГ 1: Ввод домена ===
log_step "Шаг 1: Настройка домена"
read -p "🌐 Введите домен для загрузки файлов (например, media.norest.art): " MEDIA_DOMAIN < /dev/tty
MEDIA_DOMAIN=$(echo "$MEDIA_DOMAIN" | xargs | sed 's|https\?://||' | sed 's|/$||')

if [[ -z "$MEDIA_DOMAIN" ]]; then
    log_error "Домен не может быть пустым"
    exit 1
fi
log_success "Домен: $MEDIA_DOMAIN"

# === ШАГ 2: Ввод пользователя ===
log_step "Шаг 2: Пользователь для загрузки"
read -p "👤 Введите имя пользователя для загрузки [keymaster]: " UPLOAD_USER < /dev/tty
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
echo "   (вставьте ключ и нажмите Enter):"
read -r SSH_PUBLIC_KEY < /dev/tty

if [[ -z "$SSH_PUBLIC_KEY" ]]; then
    log_error "SSH ключ не может быть пустым"
    exit 1
fi
log_success "SSH-ключ принят"

# === ШАГ 4: Установка зависимостей ===
log_step "Шаг 4: Установка необходимых пакетов"
log_info "Запускаем обновление репозиториев и установку пакетов..."
echo "   Пакеты: nginx, openssh-server, curl, wget, ufw/firewalld"
echo ""

case $OS_ID in
    ubuntu|debian)
        log_info "Выполнение: apt-get update"
        apt-get update
        echo ""
        log_info "Выполнение: apt-get install -y nginx openssh-server curl wget ufw"
        apt-get install -y nginx openssh-server curl wget ufw
        ;;
    centos|rhel|fedora|almalinux|rocky)
        if command -v dnf &> /dev/null; then
            log_info "Выполнение: dnf install -y nginx openssh-server curl wget firewalld"
            dnf install -y nginx openssh-server curl wget firewalld
        else
            log_info "Выполнение: yum install -y nginx openssh-server curl wget firewalld"
            yum install -y nginx openssh-server curl wget firewalld
        fi
        ;;
    *)
        log_warn "Неизвестная ОС: $OS_ID"
        log_info "Попытка установки через доступные менеджеры..."
        if command -v apt-get &> /dev/null; then
            apt-get update && apt-get install -y nginx openssh-server curl wget
        elif command -v yum &> /dev/null; then
            yum install -y nginx openssh-server curl wget
        elif command -v dnf &> /dev/null; then
            dnf install -y nginx openssh-server curl wget
        else
            log_error "Не удалось установить пакеты автоматически."
            log_error "Установите вручную: nginx, openssh-server, curl, wget"
            exit 1
        fi
        ;;
esac

log_success "Пакеты установлены"

# === ШАГ 5: Создание пользователя ===
log_step "Шаг 5: Создание пользователя $UPLOAD_USER"
if id "$UPLOAD_USER" &>/dev/null; then
    log_warn "Пользователь $UPLOAD_USER уже существует — пропускаем создание"
else
    log_info "Выполнение: useradd -m -s /bin/bash -G www-data $UPLOAD_USER"
    useradd -m -s /bin/bash -G www-data "$UPLOAD_USER" 2>/dev/null || \
    useradd -m -s /bin/bash "$UPLOAD_USER"
    log_success "Пользователь $UPLOAD_USER создан"
fi

# === ШАГ 6: Настройка SSH ключа ===
log_step "Шаг 6: Настройка SSH-доступа"
SSH_DIR="/home/$UPLOAD_USER/.ssh"
log_info "Создание директории: $SSH_DIR"
mkdir -p "$SSH_DIR"

log_info "Запись публичного ключа в authorized_keys"
echo "$SSH_PUBLIC_KEY" > "$SSH_DIR/authorized_keys"

log_info "Установка прав: chmod 700 $SSH_DIR && chmod 600 authorized_keys"
chmod 700 "$SSH_DIR"
chmod 600 "$SSH_DIR/authorized_keys"
chown -R "$UPLOAD_USER:$UPLOAD_USER" "$SSH_DIR"
log_success "SSH-ключ настроен"

# Настройка SSH-сервера на порт 6934
log_info "Проверка конфигурации SSH (/etc/ssh/sshd_config)"
SSH_CONFIG="/etc/ssh/sshd_config"
if ! grep -q "^Port 6934" "$SSH_CONFIG" 2>/dev/null; then
    log_info "Добавление строки: Port 6934"
    sed -i '/^#Port 22/a Port 6934' "$SSH_CONFIG" 2>/dev/null || echo "Port 6934" >> "$SSH_CONFIG"
    sed -i 's/^#PubkeyAuthentication yes/PubkeyAuthentication yes/' "$SSH_CONFIG" 2>/dev/null || true
    sed -i 's/^PubkeyAuthentication no/PubkeyAuthentication yes/' "$SSH_CONFIG" 2>/dev/null || true
    log_success "Порт 6934 добавлен в конфигурацию SSH"
else
    log_warn "Порт 6934 уже указан в конфигурации"
fi

log_info "Перезапуск SSH-сервиса"
systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
log_success "SSH-сервис перезапущен"

# === ШАГ 7: Настройка папки для загрузок ===
log_step "Шаг 7: Создание папки для загрузок"
UPLOAD_DIR="/var/www/uploads"
log_info "Создание директории: $UPLOAD_DIR"
mkdir -p "$UPLOAD_DIR"

log_info "Настройка прав: chown -R $UPLOAD_USER:$UPLOAD_USER $UPLOAD_DIR"
chown -R "$UPLOAD_USER:$UPLOAD_USER" "$UPLOAD_DIR"
chmod 755 "$UPLOAD_DIR"
log_success "Папка $UPLOAD_DIR готова"

# === ШАГ 8: Настройка nginx ===
log_step "Шаг 8: Настройка nginx для домена $MEDIA_DOMAIN"
NGINX_CONF="/etc/nginx/sites-available/$MEDIA_DOMAIN"
NGINX_LINK="/etc/nginx/sites-enabled/$MEDIA_DOMAIN"

log_info "Создание конфигурационного файла: $NGINX_CONF"
cat > "$NGINX_CONF" << EOF
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
    }

    location ~ /\. {
        deny all;
        return 404;
    }

    access_log /var/log/nginx/${MEDIA_DOMAIN}_access.log;
    error_log /var/log/nginx/${MEDIA_DOMAIN}_error.log;
}
EOF
log_success "Конфиг создан"

if [[ ! -L "$NGINX_LINK" ]] && [[ ! -f "$NGINX_LINK" ]]; then
    log_info "Создание симлинка: $NGINX_LINK -> $NGINX_CONF"
    ln -s "$NGINX_CONF" "$NGINX_LINK"
fi

log_info "Проверка конфигурации: nginx -t"
nginx -t

log_info "Перезапуск nginx: systemctl restart nginx"
systemctl enable nginx
systemctl restart nginx
log_success "nginx запущен и работает"

# === ШАГ 9: Настройка фаервола ===
log_step "Шаг 9: Настройка фаервола"
if command -v ufw &> /dev/null; then
    log_info "UFW обнаружен — добавляем правила"
    echo "   ufw allow 22/tcp"
    ufw allow 22/tcp 2>/dev/null || true
    echo "   ufw allow 6934/tcp"
    ufw allow 6934/tcp 2>/dev/null || true
    echo "   ufw allow 80/tcp"
    ufw allow 80/tcp 2>/dev/null || true
    echo "   ufw allow 443/tcp"
    ufw allow 443/tcp 2>/dev/null || true
    echo "y" | ufw enable 2>/dev/null || true
    log_success "Правила UFW применены"
    
elif command -v firewall-cmd &> /dev/null; then
    log_info "firewalld обнаружен — добавляем правила"
    echo "   firewall-cmd --permanent --add-service=ssh"
    firewall-cmd --permanent --add-service=ssh 2>/dev/null || true
    echo "   firewall-cmd --permanent --add-port=6934/tcp"
    firewall-cmd --permanent --add-port=6934/tcp 2>/dev/null || true
    echo "   firewall-cmd --permanent --add-service=http"
    firewall-cmd --permanent --add-service=http 2>/dev/null || true
    echo "   firewall-cmd --permanent --add-service=https"
    firewall-cmd --permanent --add-service=https 2>/dev/null || true
    echo "   firewall-cmd --reload"
    firewall-cmd --reload 2>/dev/null || true
    log_success "Правила firewalld применены"
else
    log_warn "Фаервол не обнаружен"
    log_info "Вручную откройте порты: 22, 6934, 80, 443"
fi

# === ШАГ 10: Финальная настройка прав ===
log_step "Шаг 10: Финальная настройка прав доступа"
log_info "chmod 775 $UPLOAD_DIR"
chmod 775 "$UPLOAD_DIR"
log_info "setfacl -m u:$UPLOAD_USER:rwx $UPLOAD_DIR"
setfacl -m u:"$UPLOAD_USER":rwx "$UPLOAD_DIR" 2>/dev/null || true
log_success "Права доступа настроены"

# === ШАГ 11: Тестовый файл ===
log_step "Шаг 11: Создание тестового файла"
TEST_FILE="$UPLOAD_DIR/test_keymaster.txt"
echo "KeyMaster server is ready! $(date)" > "$TEST_FILE"
chown "$UPLOAD_USER:$UPLOAD_USER" "$TEST_FILE"
log_success "Тестовый файл создан: $TEST_FILE"

# === ШАГ 12: Итоговая информация ===
log_step "✅ Настройка завершена!"
echo "╔════════════════════════════════════════════════════╗"
echo "║  🎉 Сервер KeyMaster готов к работе!              ║"
echo "╚════════════════════════════════════════════════════╝"
echo ""
echo "📋 Параметры подключения:"
echo "   • Домен медиа:      $MEDIA_DOMAIN"
echo "   • Пользователь:     $UPLOAD_USER"
echo "   • SSH порт:         6934"
echo "   • Папка загрузок:   $UPLOAD_DIR"
echo "   • Веб-доступ:       http://$MEDIA_DOMAIN/filename.jpg"
echo ""
echo "🔗 Пример для скрипта KeyMaster:"
echo "   media_domain = \"https://$MEDIA_DOMAIN\""
echo "   server_port = 6934"
echo "   username = \"$UPLOAD_USER\""
echo "   remote_folder = \"$UPLOAD_DIR\""
echo ""
echo "🧪 Быстрая проверка:"
echo "   1. SSH: ssh -p 6934 $UPLOAD_USER@$(hostname -I | awk '{print $1}' | head -1)"
echo "   2. HTTP: curl -I http://$MEDIA_DOMAIN/test_keymaster.txt"
echo ""
echo "🔒 HTTPS (рекомендуется):"
echo "   certbot --nginx -d $MEDIA_DOMAIN"
echo ""
log_success "Готово! Сервер ожидает подключения от скрипта KeyMaster 🚀"
echo ""
