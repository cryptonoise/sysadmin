#!/bin/bash
# Запуск: curl -fsSL https://raw.githubusercontent.com/cryptonoise/sysadmin/refs/heads/main/server4keymaster.sh | bash

# === ВЕРСИЯ СКРИПТА ===
SCRIPT_VERSION="v1.3"
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
log_step()    { echo -e "\n${CYAN}────────────────────────────────${NC}"; echo -e "${CYAN}[ ⚙️ ]${NC} $1"; echo -e "${CYAN}────────────────────────────────${NC}\n"; }
log_detail()  { echo -e "   ${CYAN}→${NC} $1"; }

# === Cloudflare IP ranges ===
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

# === ЗАГОЛОВОК ===
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
    echo "   1 - Продолжить настройку"
    echo "   2 - 🗑️  ОТКАТИТЬ все изменения"
    echo "   3 - Выйти"
    read -p "Введите номер [1-3]: " ACTION_CHOICE < /dev/tty
    case $ACTION_CHOICE in
        2)
            log_step "🗑️  Откат"
            PREV_USER=$(grep '^USER=' "$MARKER_FILE" | cut -d'=' -f2)
            PREV_DOMAIN=$(grep '^DOMAIN=' "$MARKER_FILE" | cut -d'=' -f2)
            PREV_UPLOAD_DIR=$(grep '^UPLOAD_DIR=' "$MARKER_FILE" | cut -d'=' -f2)
            PREV_SSH_PORT=$(grep '^SSH_PORT=' "$MARKER_FILE" | cut -d'=' -f2)
            PREV_SSH_PORT=${PREV_SSH_PORT:-6934}
            echo ""
            [[ -n "$PREV_USER" ]] && id "$PREV_USER" &>/dev/null && { log_detail "Удаление пользователя: $PREV_USER"; userdel -r "$PREV_USER" 2>/dev/null || true; }
            [[ -n "$PREV_UPLOAD_DIR" ]] && [[ -d "$PREV_UPLOAD_DIR" ]] && { log_detail "Удаление папки: $PREV_UPLOAD_DIR"; rm -rf "$PREV_UPLOAD_DIR"; }
            [[ -n "$PREV_DOMAIN" ]] && { rm -f "/etc/nginx/sites-available/$PREV_DOMAIN" "/etc/nginx/sites-enabled/$PREV_DOMAIN" 2>/dev/null; systemctl reload nginx 2>/dev/null || true; }
            SSH_CONFIG="/etc/ssh/sshd_config"
            grep -q "^Port $PREV_SSH_PORT" "$SSH_CONFIG" 2>/dev/null && { sed -i "/^Port $PREV_SSH_PORT/d" "$SSH_CONFIG"; systemctl restart sshd 2>/dev/null || true; }
            command -v ufw &>/dev/null && { ufw delete allow $PREV_SSH_PORT/tcp 2>/dev/null; ufw delete allow 80/tcp 2>/dev/null; ufw delete allow 443/tcp 2>/dev/null; } || true
            rm -f "$MARKER_FILE"
            echo -e "${GREEN}✅ Откат завершён${NC}"; exit 0
            ;;
        3) exit 0 ;;
        1) log_info "Продолжение настройки" ;;
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

# === ШАГ 2-4: Пользователь, ключ, порт ===
log_step "Шаг 2: Пользователь"
read -p "👤 Имя пользователя [по-умолчанию keymaster]: " UPLOAD_USER < /dev/tty
UPLOAD_USER=${UPLOAD_USER:-keymaster}
[[ -z "$UPLOAD_USER" ]] && { log_error "Имя не может быть пустым"; exit 1; }
log_success "Пользователь: $UPLOAD_USER"

log_step "Шаг 3: SSH-ключ"
echo "🔑 Введите публичный SSH-ключ:"
read -r SSH_PUBLIC_KEY < /dev/tty
[[ -z "$SSH_PUBLIC_KEY" ]] && { log_error "Ключ не может быть пустым"; exit 1; }
log_success "Ключ принят"

log_step "Шаг 4: SSH-порт"
read -p "🔌 Порт [по-умолчанию 6934]: " SSH_PORT < /dev/tty
SSH_PORT=${SSH_PORT:-6934}
[[ ! "$SSH_PORT" =~ ^[0-9]+$ || "$SSH_PORT" -lt 1 || "$SSH_PORT" -gt 65535 ]] && { log_error "Неверный порт"; exit 1; }
[[ "$SSH_PORT" == "22" ]] && log_warn "Порт 22 — стандартный"
log_success "Порт: $SSH_PORT"

# === ШАГ 5: Пакеты ===
log_step "Шаг 5: Установка пакетов"
log_detail "Обновление репозиториев..."
case $OS_ID in
    ubuntu|debian)
        apt-get update
        log_detail "Установка: nginx, openssh-server, curl, wget, ufw"
        apt-get install -y nginx openssh-server curl wget ufw
        ;;
    centos|rhel|fedora|almalinux|rocky)
        command -v dnf &>/dev/null && dnf install -y nginx openssh-server curl wget firewalld || yum install -y nginx openssh-server curl wget firewalld
        ;;
    *) log_error "Неизвестная ОС: $OS_ID"; exit 1 ;;
esac
log_success "Пакеты установлены"

# === ШАГ 6: Пользователь ===
log_step "Шаг 6: Создание пользователя"
if id "$UPLOAD_USER" &>/dev/null; then
    log_detail "Пользователь $UPLOAD_USER уже существует"
    log_warn "Пропускаем создание"
else
    log_detail "Выполнение: useradd -m -s /bin/bash -G www-data $UPLOAD_USER"
    useradd -m -s /bin/bash -G www-data "$UPLOAD_USER" 2>/dev/null || useradd -m -s /bin/bash "$UPLOAD_USER"
    log_detail "Домашняя папка: /home/$UPLOAD_USER"
    log_detail "Группы: $(groups $UPLOAD_USER)"
    log_success "Пользователь $UPLOAD_USER создан"
fi

# === ШАГ 7: SSH ===
log_step "Шаг 7: Настройка SSH"
SSH_DIR="/home/$UPLOAD_USER/.ssh"
log_detail "Создание директории: $SSH_DIR"
mkdir -p "$SSH_DIR"
log_detail "Запись ключа в: $SSH_DIR/authorized_keys"
echo "$SSH_PUBLIC_KEY" > "$SSH_DIR/authorized_keys"
log_detail "Установка прав: chmod 700 $SSH_DIR"
chmod 700 "$SSH_DIR"
log_detail "Установка прав: chmod 600 $SSH_DIR/authorized_keys"
chmod 600 "$SSH_DIR/authorized_keys"
log_detail "Смена владельца: chown -R $UPLOAD_USER:$UPLOAD_USER $SSH_DIR"
chown -R "$UPLOAD_USER:$UPLOAD_USER" "$SSH_DIR"
log_success "SSH-ключ настроен"

SSH_CONFIG="/etc/ssh/sshd_config"
if ! grep -q "^Port $SSH_PORT" "$SSH_CONFIG" 2>/dev/null; then
    log_detail "Добавление порта $SSH_PORT в $SSH_CONFIG"
    sed -i "/^#Port 22/a Port $SSH_PORT" "$SSH_CONFIG" 2>/dev/null || echo "Port $SSH_PORT" >> "$SSH_CONFIG"
    log_success "Порт $SSH_PORT добавлен"
else
    log_warn "Порт $SSH_PORT уже в конфигурации"
fi
log_detail "Перезапуск SSH-сервиса"
systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
log_success "SSH перезапущен"

# === ШАГ 8: Папка загрузок ===
log_step "Шаг 8: Папка для загрузок"
UPLOAD_DIR="/var/www/uploads"
log_detail "Создание директории: $UPLOAD_DIR"
mkdir -p "$UPLOAD_DIR"
log_detail "Настройка прав: chown -R $UPLOAD_USER:www-data $UPLOAD_DIR"
chown -R "$UPLOAD_USER:www-data" "$UPLOAD_DIR"
log_detail "Настройка прав: chmod 755 $UPLOAD_DIR"
chmod 755 "$UPLOAD_DIR"
log_detail "Папка: $UPLOAD_DIR"
log_detail "Владелец: $(stat -c '%U:%G' "$UPLOAD_DIR")"
log_detail "Права: $(stat -c '%a' "$UPLOAD_DIR")"
log_success "Папка готова"

# === ШАГ 9: Удаление дефолтного nginx конфига ===
log_step "Шаг 9: Очистка дефолтных конфигов nginx"
log_detail "Удаление /etc/nginx/sites-enabled/default"
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
log_detail "Удаление /etc/nginx/conf.d/default.conf"
rm -f /etc/nginx/conf.d/default.conf 2>/dev/null || true
log_success "Дефолтные конфиги удалены"

# === ШАГ 10: Создание nginx конфига ===
log_step "Шаг 10: Настройка nginx"
NGINX_CONF="/etc/nginx/sites-available/$MEDIA_DOMAIN"
NGINX_LINK="/etc/nginx/sites-enabled/$MEDIA_DOMAIN"

log_detail "Создание конфигурации: $NGINX_CONF"

cat > "$NGINX_CONF" << EOF
# Cloudflare: получаем реальный IP клиента
$CLOUDFLARE_IPS

server {
    listen 80;
    listen [::]:80;
    
    server_name $MEDIA_DOMAIN www.$MEDIA_DOMAIN;
    
    # Корневая папка с файлами
    root $UPLOAD_DIR;
    index index.html;
    
    # Скрываем версию nginx
    server_tokens off;
    
    # Разрешаем большие файлы (до 100MB для OpenAI)
    client_max_body_size 100M;
    
    # CORS заголовки для OpenAI
    add_header Access-Control-Allow-Origin *;
    add_header Access-Control-Allow-Methods 'GET, OPTIONS';
    add_header Access-Control-Allow-Headers 'Content-Type';
    
    # Основной location — раздача файлов
    location / {
        # Если файл есть — отдаём, если нет — 404
        try_files \$uri \$uri/ =404;
        
        # Отключаем листинг директорий
        autoindex off;
        
        # MIME-типы для изображений и видео
        types {
            image/jpeg jpg jpeg;
            image/png png;
            image/webp webp;
            image/gif gif;
            video/mp4 mp4;
            video/quicktime mov;
            video/x-msvideo avi;
            video/x-matroska mkv;
            video/x-ms-wmv wmv;
        }
        default_type application/octet-stream;
    }
    
    # Блокируем доступ к скрытым файлам (.git, .env, .htaccess и т.д.)
    location ~ /\. {
        deny all;
        return 404;
    }
    
    # Логирование
    access_log /var/log/nginx/${MEDIA_DOMAIN}_access.log;
    error_log /var/log/nginx/${MEDIA_DOMAIN}_error.log;
}
EOF

log_success "Конфиг создан"

# Создаём симлинк
if [[ ! -L "$NGINX_LINK" ]] && [[ ! -f "$NGINX_LINK" ]]; then
    log_detail "Создание симлинка: $NGINX_LINK -> $NGINX_CONF"
    ln -s "$NGINX_CONF" "$NGINX_LINK"
fi

# Проверка и перезагрузка nginx
log_detail "Проверка конфигурации: nginx -t"
nginx -t
log_detail "Перезагрузка nginx: systemctl reload nginx"
systemctl reload nginx
log_success "nginx перезапущен"

# === ШАГ 11: Фаервол ===
log_step "Шаг 11: Настройка фаервола"
if command -v ufw &>/dev/null; then
    log_detail "UFW: разрешаем порты"
    log_detail "  → ufw allow 22/tcp"
    ufw allow 22/tcp 2>/dev/null || true
    log_detail "  → ufw allow $SSH_PORT/tcp"
    ufw allow $SSH_PORT/tcp 2>/dev/null || true
    log_detail "  → ufw allow 80/tcp"
    ufw allow 80/tcp 2>/dev/null || true
    log_detail "Включение UFW..."
    echo "y" | ufw enable 2>/dev/null || true
    log_success "✅ Правила UFW применены"
    log_detail "Статус: $(ufw status verbose | head -3)"
elif command -v firewall-cmd &>/dev/null; then
    log_detail "firewalld: добавляем сервисы"
    firewall-cmd --permanent --add-service=ssh 2>/dev/null || true
    firewall-cmd --permanent --add-port=$SSH_PORT/tcp 2>/dev/null || true
    firewall-cmd --permanent --add-service=http 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
    log_success "✅ Правила firewalld применены"
else
    log_warn "Фаервол не обнаружен"
    log_detail "Вручную откройте: 22, $SSH_PORT, 80"
fi

# === ШАГ 12: Права доступа ===
log_step "Шаг 12: Настройка прав доступа"
log_detail "chmod 755 $UPLOAD_DIR"
chmod 755 "$UPLOAD_DIR"
log_detail "chown -R $UPLOAD_USER:www-data $UPLOAD_DIR"
chown -R "$UPLOAD_USER:www-data" "$UPLOAD_DIR"
log_detail "find $UPLOAD_DIR -type f -exec chmod 644 {} \\;"
find "$UPLOAD_DIR" -type f -exec chmod 644 {} \; 2>/dev/null || true
log_detail "find $UPLOAD_DIR -type d -exec chmod 755 {} \\;"
find "$UPLOAD_DIR" -type d -exec chmod 755 {} \; 2>/dev/null || true
log_detail "Итоговые права:"
log_detail "  Папка: $(stat -c '%a %U:%G' "$UPLOAD_DIR")"
log_detail "  Файлы: 644 (чтение для всех)"
log_success "✅ Права настроены"

# === ШАГ 13: Тестовый файл ===
log_step "Шаг 13: Создание тестового файла"
TEST_FILE="$UPLOAD_DIR/test_keymaster.txt"
log_detail "Путь: $TEST_FILE"
echo "KeyMaster server is ready! $(date)" > "$TEST_FILE"
log_detail "Владелец: chown $UPLOAD_USER:www-data"
chown "$UPLOAD_USER:www-data" "$TEST_FILE"
log_detail "Права: chmod 644"
chmod 644 "$TEST_FILE"
log_detail "Содержимое: $(cat "$TEST_FILE")"
log_detail "Проверка доступа: $(test -r "$TEST_FILE" && echo 'читаемый' || echo 'НЕ читаемый')"
log_success "✅ Файл создан и доступен"

# === ШАГ 14: Метка ===
log_step "Шаг 14: Метка установки"
log_detail "Файл: $MARKER_FILE"
cat > "$MARKER_FILE" << EOF
INSTALLED_AT=$(date '+%Y-%m-%d %H:%M:%S')
SCRIPT_VERSION=$SCRIPT_VERSION
DOMAIN=$MEDIA_DOMAIN
USER=$UPLOAD_USER
UPLOAD_DIR=$UPLOAD_DIR
SSH_PORT=$SSH_PORT
EOF
chmod 644 "$MARKER_FILE"
log_detail "Содержимое:"
cat "$MARKER_FILE" | sed 's/^/   /'
log_success "✅ Метка создана"

# === ШАГ 15: Итог ===
log_step "✅ Настройка завершена!"
echo -e "${RED}────────────────────────────────${NC}"
echo "🎉 Сервер KeyMaster готов к работе!"
echo -e "${RED}────────────────────────────────${NC}"
echo ""
echo "📋 Параметры:"
echo "   • Домен:            $MEDIA_DOMAIN"
echo "   • Пользователь:     $UPLOAD_USER"
echo "   • SSH порт:         $SSH_PORT"
echo "   • Папка загрузок:   $UPLOAD_DIR"
echo ""
echo "🧪 Проверка (кликните):"
echo -e "   🔗 https://$MEDIA_DOMAIN/test_keymaster.txt"
echo ""
