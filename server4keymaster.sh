#!/bin/bash
# server4keymaster.sh - Настройка сервера для KeyMaster
# Запуск: curl -fsSL https://raw.githubusercontent.com/cryptonoise/sysadmin/refs/heads/main/server4keymaster.sh | sh

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info()    { echo -e "${BLUE}[ℹ️]${NC} $1"; }
log_success() { echo -e "${GREEN}[✅]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[⚠️]${NC} $1"; }
log_error()   { echo -e "${RED}[❌]${NC} $1"; }

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
echo ""
echo "🌐 Настройка сервера для KeyMaster"
echo "=================================="
read -p "Введите домен для загрузки файлов (например, media.norest.art): " MEDIA_DOMAIN < /dev/tty
MEDIA_DOMAIN=$(echo "$MEDIA_DOMAIN" | xargs | sed 's|https\?://||' | sed 's|/$||')

if [[ -z "$MEDIA_DOMAIN" ]]; then
    log_error "Домен не может быть пустым"
    exit 1
fi
log_info "Домен: $MEDIA_DOMAIN"

# === ШАГ 2: Ввод пользователя ===
echo ""
read -p "Введите имя пользователя для загрузки [keymaster]: " UPLOAD_USER < /dev/tty
UPLOAD_USER=${UPLOAD_USER:-keymaster}
UPLOAD_USER=$(echo "$UPLOAD_USER" | xargs)

if [[ -z "$UPLOAD_USER" ]]; then
    log_error "Имя пользователя не может быть пустым"
    exit 1
fi
log_info "Пользователь: $UPLOAD_USER"

# === ШАГ 3: Ввод SSH публичного ключа ===
echo ""
echo "🔑 Введите публичный SSH-ключ для пользователя $UPLOAD_USER"
echo "Формат: ssh-rsa AAAAB3... или ssh-ed25519 AAAAC3... (можно вставить целиком)"
echo "Нажмите Enter после вставки ключа:"
read -r SSH_PUBLIC_KEY < /dev/tty

if [[ -z "$SSH_PUBLIC_KEY" ]]; then
    log_error "SSH ключ не может быть пустым"
    exit 1
fi

# === ШАГ 4: Установка зависимостей ===
log_info "Установка необходимых пакетов..."

case $OS_ID in
    ubuntu|debian)
        apt-get update -qq
        apt-get install -y -qq nginx openssh-server curl wget ufw > /dev/null 2>&1
        ;;
    centos|rhel|fedora|almalinux|rocky)
        if command -v dnf &> /dev/null; then
            dnf install -y -q nginx openssh-server curl wget firewalld > /dev/null 2>&1
        else
            yum install -y -q nginx openssh-server curl wget firewalld > /dev/null 2>&1
        fi
        ;;
    *)
        log_warn "Неизвестная ОС, попытка установки через стандартные менеджеры..."
        if command -v apt-get &> /dev/null; then
            apt-get update -qq && apt-get install -y -qq nginx openssh-server curl wget > /dev/null 2>&1
        elif command -v yum &> /dev/null; then
            yum install -y -q nginx openssh-server curl wget > /dev/null 2>&1
        elif command -v dnf &> /dev/null; then
            dnf install -y -q nginx openssh-server curl wget > /dev/null 2>&1
        else
            log_error "Не удалось установить пакеты автоматически. Установите: nginx, openssh-server"
            exit 1
        fi
        ;;
esac

# === ШАГ 5: Создание пользователя ===
if id "$UPLOAD_USER" &>/dev/null; then
    log_warn "Пользователь $UPLOAD_USER уже существует, пропускаем создание"
else
    log_info "Создание пользователя $UPLOAD_USER..."
    useradd -m -s /bin/bash -G www-data "$UPLOAD_USER" 2>/dev/null || \
    useradd -m -s /bin/bash "$UPLOAD_USER"
fi

# === ШАГ 6: Настройка SSH ключа ===
log_info "Настройка SSH-доступа для $UPLOAD_USER..."
SSH_DIR="/home/$UPLOAD_USER/.ssh"
mkdir -p "$SSH_DIR"
echo "$SSH_PUBLIC_KEY" > "$SSH_DIR/authorized_keys"
chmod 700 "$SSH_DIR"
chmod 600 "$SSH_DIR/authorized_keys"
chown -R "$UPLOAD_USER:$UPLOAD_USER" "$SSH_DIR"

# Настройка SSH-сервера на порт 6934
SSH_CONFIG="/etc/ssh/sshd_config"
if ! grep -q "^Port 6934" "$SSH_CONFIG" 2>/dev/null; then
    log_info "Добавление порта 6934 в конфигурацию SSH..."
    # Добавляем порт, не удаляя стандартный 22
    sed -i '/^#Port 22/a Port 6934' "$SSH_CONFIG" 2>/dev/null || \
    echo "Port 6934" >> "$SSH_CONFIG"
    
    # Разрешаем аутентификацию по ключам
    sed -i 's/^#PubkeyAuthentication yes/PubkeyAuthentication yes/' "$SSH_CONFIG" 2>/dev/null || true
    sed -i 's/^PubkeyAuthentication no/PubkeyAuthentication yes/' "$SSH_CONFIG" 2>/dev/null || true
fi

# Перезапуск SSH
log_info "Перезапуск SSH-сервиса..."
systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true

# === ШАГ 7: Настройка папки для загрузок ===
UPLOAD_DIR="/var/www/uploads"
log_info "Создание папки для загрузок: $UPLOAD_DIR"
mkdir -p "$UPLOAD_DIR"
chown -R "$UPLOAD_USER:$UPLOAD_USER" "$UPLOAD_DIR"
chmod 755 "$UPLOAD_DIR"

# === ШАГ 8: Настройка nginx ===
log_info "Настройка nginx для домена $MEDIA_DOMAIN..."

NGINX_CONF="/etc/nginx/sites-available/$MEDIA_DOMAIN"
NGINX_LINK="/etc/nginx/sites-enabled/$MEDIA_DOMAIN"

# Создаём конфиг
cat > "$NGINX_CONF" << EOF
server {
    listen 80;
    listen [::]:80;
    server_name $MEDIA_DOMAIN www.$MEDIA_DOMAIN;

    root $UPLOAD_DIR;
    index index.html;

    # Разрешаем загрузку файлов до 100MB (для OpenAI vision)
    client_max_body_size 100M;

    # CORS для OpenAI
    add_header Access-Control-Allow-Origin *;
    add_header Access-Control-Allow-Methods 'GET, OPTIONS';
    add_header Access-Control-Allow-Headers 'Content-Type';

    location / {
        try_files \$uri \$uri/ =404;
        autoindex off;
        
        # Правильные MIME-типы для изображений и видео
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

    # Блокируем доступ к скрытым файлам
    location ~ /\. {
        deny all;
        return 404;
    }

    # Логирование
    access_log /var/log/nginx/${MEDIA_DOMAIN}_access.log;
    error_log /var/log/nginx/${MEDIA_DOMAIN}_error.log;
}
EOF

# Создаём симлинк если не существует
if [[ ! -L "$NGINX_LINK" ]] && [[ ! -f "$NGINX_LINK" ]]; then
    ln -s "$NGINX_CONF" "$NGINX_LINK"
fi

# Проверяем и перезапускаем nginx
log_info "Проверка конфигурации nginx..."
nginx -t

if nginx -t &>/dev/null; then
    log_info "Перезапуск nginx..."
    systemctl enable nginx
    systemctl restart nginx
    log_success "nginx запущен"
else
    log_error "Ошибка в конфигурации nginx!"
    nginx -t
    exit 1
fi

# === ШАГ 9: Настройка фаервола ===
log_info "Настройка фаервола..."

if command -v ufw &> /dev/null; then
    # Ubuntu/Debian
    ufw allow 22/tcp 2>/dev/null || true
    ufw allow 6934/tcp 2>/dev/null || true
    ufw allow 80/tcp 2>/dev/null || true
    ufw allow 443/tcp 2>/dev/null || true
    echo "y" | ufw enable 2>/dev/null || true
    log_success "Правила UFW применены: порты 22, 6934, 80, 443"
    
elif command -v firewall-cmd &> /dev/null; then
    # CentOS/RHEL
    firewall-cmd --permanent --add-service=ssh 2>/dev/null || true
    firewall-cmd --permanent --add-port=6934/tcp 2>/dev/null || true
    firewall-cmd --permanent --add-service=http 2>/dev/null || true
    firewall-cmd --permanent --add-service=https 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
    log_success "Правила firewalld применены: порты 22, 6934, 80, 443"
else
    log_warn "Фаервол не обнаружен или не поддерживается. Настройте вручную порты: 22, 6934, 80, 443"
fi

# === ШАГ 10: Настройка прав доступа ===
log_info "Настройка прав доступа..."
# Даём пользователю право записи в папку загрузок
chmod 775 "$UPLOAD_DIR"
setfacl -m u:"$UPLOAD_USER":rwx "$UPLOAD_DIR" 2>/dev/null || true

# === ШАГ 11: Тестовый файл ===
TEST_FILE="$UPLOAD_DIR/test_keymaster.txt"
echo "KeyMaster server is ready! $(date)" > "$TEST_FILE"
chown "$UPLOAD_USER:$UPLOAD_USER" "$TEST_FILE"
log_info "Создан тестовый файл: $TEST_FILE"

# === ШАГ 12: Вывод итоговой информации ===
echo ""
echo "╔════════════════════════════════════════════════════╗"
echo "║  ✅ Настройка сервера для KeyMaster завершена!     ║"
echo "╚════════════════════════════════════════════════════╝"
echo ""
echo "📋 Параметры подключения:"
echo "   • Домен медиа:      $MEDIA_DOMAIN"
echo "   • Пользователь:     $UPLOAD_USER"
echo "   • SSH порт:         6934"
echo "   • Папка загрузок:   $UPLOAD_DIR"
echo "   • Веб-доступ:       http://$MEDIA_DOMAIN/filename.jpg"
echo ""
echo "🔗 Пример использования в скрипте KeyMaster:"
echo "   media_domain = \"https://$MEDIA_DOMAIN\""
echo "   server_port = 6934"
echo "   username = \"$UPLOAD_USER\""
echo "   remote_folder = \"$UPLOAD_DIR\""
echo ""
echo "🧪 Проверка работы:"
echo "   1. SSH: ssh -p 6934 $UPLOAD_USER@$(hostname -I | awk '{print $1}')"
echo "   2. HTTP: curl -I http://$MEDIA_DOMAIN/test_keymaster.txt"
echo ""
echo "🔒 Для HTTPS:"
echo "   Установите SSL-сертификат через Let's Encrypt:"
echo "   certbot --nginx -d $MEDIA_DOMAIN"
echo ""
log_success "Готово! Сервер ожидает подключения от скрипта KeyMaster 🚀"
echo ""
