#!/bin/bash
# Запуск: curl -fsSL https://raw.githubusercontent.com/cryptonoise/sysadmin/refs/heads/main/server4keymaster.sh | bash

# === ВЕРСИЯ СКРИПТА ===
SCRIPT_VERSION="v1.5"
SCRIPT_NAME="KeyMaster Server"

# === МЕТКА УСТАНОВКИ ===
MARKER_FILE="/etc/keymaster-server-setup.marker"
DOCKER_DIR="/opt/keymaster-docker"
UPLOAD_DIR_HOST="/var/www/keymaster-media"  # 🎯 Новый путь для загрузок

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
    echo "   1 - Продолжить настройку (пересоздать контейнер)"
    echo "   2 - 🗑️  ОТКАТИТЬ все изменения (удалить контейнер и конфиги)"
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
            
            # Остановка и удаление контейнера
            if command -v docker &>/dev/null; then
                cd "$DOCKER_DIR" 2>/dev/null && docker compose down 2>/dev/null || true
                docker rm -f keymaster 2>/dev/null || true
                log_detail "Контейнер keymaster удален"
            fi
            
            # Удаление файлов докера
            if [[ -d "$DOCKER_DIR" ]]; then
                log_detail "Удаление директории $DOCKER_DIR"
                rm -rf "$DOCKER_DIR"
            fi

            # Очистка хоста
            [[ -n "$PREV_USER" ]] && id "$PREV_USER" &>/dev/null && { log_detail "Удаление пользователя: $PREV_USER"; userdel -r "$PREV_USER" 2>/dev/null || true; }
            [[ -n "$PREV_UPLOAD_DIR" ]] && [[ -d "$PREV_UPLOAD_DIR" ]] && { log_detail "Удаление папки: $PREV_UPLOAD_DIR"; rm -rf "$PREV_UPLOAD_DIR"; }
            
            # Возврат SSH порта
            SSH_CONFIG="/etc/ssh/sshd_config"
            grep -q "^Port $PREV_SSH_PORT" "$SSH_CONFIG" 2>/dev/null && { sed -i "/^Port $PREV_SSH_PORT/d" "$SSH_CONFIG"; systemctl restart sshd 2>/dev/null || true; }
            
            command -v ufw &>/dev/null && { ufw delete allow $PREV_SSH_PORT/tcp 2>/dev/null; ufw delete allow 80/tcp 2>/dev/null; } || true
            
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

# === ШАГ 5: Установка Docker ===
log_step "Шаг 5: Проверка и установка Docker"

install_docker() {
    log_detail "Установка зависимостей..."
    case $OS_ID in
        ubuntu|debian)
            apt-get update
            apt-get install -y ca-certificates curl gnupg lsb-release
            mkdir -p /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null || \
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$OS_ID $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
            apt-get update
            apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
            ;;
        centos|rhel|fedora|almalinux|rocky)
            yum install -y yum-utils
            yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
            systemctl enable --now docker
            ;;
        *) log_error "Неизвестная ОС для автоустановки Docker: $OS_ID"; exit 1 ;;
    esac
}

if command -v docker &>/dev/null; then
    log_success "Docker уже установлен: $(docker --version)"
else
    log_warn "Docker не найден. Начинается установка..."
    install_docker
    log_success "Docker установлен"
fi

# Проверка docker compose
if ! docker compose version &>/dev/null; then
    log_error "Docker установлен, но плагин compose не найден."
    exit 1
fi

# === ШАГ 6: Пользователь на хосте (для SSH доступа) ===
log_step "Шаг 6: Создание пользователя на хосте"
if id "$UPLOAD_USER" &>/dev/null; then
    log_detail "Пользователь $UPLOAD_USER уже существует"
else
    log_detail "Выполнение: useradd -m -s /bin/bash $UPLOAD_USER"
    useradd -m -s /bin/bash "$UPLOAD_USER"
    log_success "Пользователь $UPLOAD_USER создан"
fi

# === ШАГ 7: SSH на хосте ===
log_step "Шаг 7: Настройка SSH на хосте"
SSH_DIR="/home/$UPLOAD_USER/.ssh"
log_detail "Создание директории: $SSH_DIR"
mkdir -p "$SSH_DIR"
log_detail "Запись ключа в: $SSH_DIR/authorized_keys"
echo "$SSH_PUBLIC_KEY" > "$SSH_DIR/authorized_keys"
chmod 700 "$SSH_DIR"
chmod 600 "$SSH_DIR/authorized_keys"
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

# === ШАГ 8: Подготовка папок для Docker ===
log_step "Шаг 8: Подготовка структуры папок"

NGINX_CONF_DIR="$DOCKER_DIR/nginx"

log_detail "Создание директорий..."
mkdir -p "$UPLOAD_DIR_HOST"
mkdir -p "$NGINX_CONF_DIR"
mkdir -p "$DOCKER_DIR"

# Права на папку uploads — nginx в контейнере работает от uid 33 (www-data)
# Делаем папку доступной для записи пользователю ключа и для контейнера
chown -R "$UPLOAD_USER:33" "$UPLOAD_DIR_HOST"
chmod 775 "$UPLOAD_DIR_HOST"

log_success "Структура создана:"
log_detail "  • Загрузки: $UPLOAD_DIR_HOST"
log_detail "  • Конфиги:  $NGINX_CONF_DIR"
log_detail "  • Docker:   $DOCKER_DIR"

# === ШАГ 9: Генерация Nginx конфига ===
log_step "Шаг 9: Генерация конфигурации Nginx"

NGINX_CONF_FILE="$NGINX_CONF_DIR/default.conf"

cat > "$NGINX_CONF_FILE" << EOF
# Cloudflare: получаем реальный IP клиента
$CLOUDFLARE_IPS

server {
    listen 80;
    listen [::]:80;
    
    server_name $MEDIA_DOMAIN www.$MEDIA_DOMAIN;
    
    # Корневая папка с файлами (путь внутри контейнера)
    root /usr/share/nginx/html;
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
    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;
}
EOF

log_success "Конфиг nginx создан"

# === ШАГ 10: Создание Docker Compose файла ===
log_step "Шаг 10: Создание docker-compose.yml"

COMPOSE_FILE="$DOCKER_DIR/docker-compose.yml"

cat > "$COMPOSE_FILE" << EOF
version: '3.8'

services:
  keymaster:
    image: nginx:alpine
    container_name: keymaster
    restart: unless-stopped
    ports:
      - "80:80"
    volumes:
      - ./nginx/default.conf:/etc/nginx/conf.d/default.conf:ro
      - ${UPLOAD_DIR_HOST}:/usr/share/nginx/html:rw
    networks:
      - web-net

networks:
  web-net:
    driver: bridge
EOF

log_success "docker-compose.yml создан"

# === ШАГ 11: Запуск контейнера ===
log_step "Шаг 11: Запуск контейнера keymaster"
cd "$DOCKER_DIR"
docker compose up -d
log_success "Контейнер запущен"
log_detail "Статус: $(docker ps --filter name=keymaster --format '{{.Status}}')"

# === ШАГ 12: Фаервол на хосте ===
log_step "Шаг 12: Настройка фаервола на хосте"
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

# === ШАГ 13: Тестовый файл ===
log_step "Шаг 13: Создание тестового файла"
TEST_FILE="$UPLOAD_DIR_HOST/test_keymaster.txt"
log_detail "Путь: $TEST_FILE"
echo "KeyMaster server is ready! $(date)" > "$TEST_FILE"
# Права для чтения веб-сервером и записи пользователем
chown "$UPLOAD_USER:33" "$TEST_FILE" 2>/dev/null || true
chmod 664 "$TEST_FILE"
log_success "✅ Файл создан и доступен"

# === ШАГ 14: Метка ===
log_step "Шаг 14: Метка установки"
log_detail "Файл: $MARKER_FILE"
cat > "$MARKER_FILE" << EOF
INSTALLED_AT=$(date '+%Y-%m-%d %H:%M:%S')
SCRIPT_VERSION=$SCRIPT_VERSION
DOMAIN=$MEDIA_DOMAIN
USER=$UPLOAD_USER
UPLOAD_DIR=$UPLOAD_DIR_HOST
SSH_PORT=$SSH_PORT
DOCKER_DIR=$DOCKER_DIR
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
echo "   • Папка загрузок:   $UPLOAD_DIR_HOST"
echo "   • Контейнер:        keymaster"
echo ""
echo "🛠 Управление:"
echo "   • Логи:             docker logs -f keymaster"
echo "   • Перезагрузка:     cd $DOCKER_DIR && docker compose restart"
echo "   • Остановка:        cd $DOCKER_DIR && docker compose down"
echo ""
echo "🧪 Проверка (кликните):"
echo -e "   🔗 http://$MEDIA_DOMAIN/test_keymaster.txt"
echo ""
