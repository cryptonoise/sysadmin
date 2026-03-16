#!/bin/bash
# server4keymaster.sh - Настройка сервера для KeyMaster
# Запуск: curl -fsSL https://raw.githubusercontent.com/cryptonoise/sysadmin/refs/heads/main/server4keymaster.sh | bash

# === ВЕРСИЯ СКРИПТА ===
SCRIPT_VERSION="v1.8"
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

# === ЗАГОЛОВОК ПРИ ЗАПУСКЕ ===
print_header() {
    echo ""
    echo -e "${RED}────────────────────────────────────────────────────────${NC}"
    echo -e "${RED}────────────────────────────────────────────────────────${NC}"
    echo -e "  ${GREEN}${SCRIPT_NAME}${NC}"
    echo -e "  Версия: ${CYAN}${SCRIPT_VERSION}${NC}"
    echo -e "${RED}────────────────────────────────────────────────────────${NC}"
    echo -e "${RED}────────────────────────────────────────────────────────${NC}"
    echo ""
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
            
            # Чтение данных из метки
            PREV_USER=$(grep '^USER=' "$MARKER_FILE" | cut -d'=' -f2)
            PREV_DOMAIN=$(grep '^DOMAIN=' "$MARKER_FILE" | cut -d'=' -f2)
            PREV_UPLOAD_DIR=$(grep '^UPLOAD_DIR=' "$MARKER_FILE" | cut -d'=' -f2)
            PREV_SSH_PORT=$(grep '^SSH_PORT=' "$MARKER_FILE" | cut -d'=' -f2)
            PREV_SSH_PORT=${PREV_SSH_PORT:-6934}
            
            echo ""
            log_info "Начало отката..."
            
            # 1. Удаление пользователя
            if id "$PREV_USER" &>/dev/null; then
                log_info "Удаление пользователя: $PREV_USER"
                userdel -r "$PREV_USER" 2>/dev/null || true
                log_success "Пользователь $PREV_USER удалён"
            else
                log_warn "Пользователь $PREV_USER не найден"
            fi
            
            # 2. Удаление папки загрузок
            if [[ -n "$PREV_UPLOAD_DIR" ]] && [[ -d "$PREV_UPLOAD_DIR" ]]; then
                log_info "Удаление папки: $PREV_UPLOAD_DIR"
                rm -rf "$PREV_UPLOAD_DIR"
                log_success "Папка $PREV_UPLOAD_DIR удалена"
            fi
            
            # 3. Удаление конфига nginx
            if [[ -n "$PREV_DOMAIN" ]]; then
                NGINX_CONF="/etc/nginx/sites-available/$PREV_DOMAIN"
                NGINX_LINK="/etc/nginx/sites-enabled/$PREV_DOMAIN"
                
                if [[ -f "$NGINX_CONF" ]]; then
                    log_info "Удаление конфига nginx: $NGINX_CONF"
                    rm -f "$NGINX_CONF"
                    log_success "Конфиг удалён"
                fi
                
                if [[ -L "$NGINX_LINK" ]]; then
                    log_info "Удаление симлинка: $NGINX_LINK"
                    rm -f "$NGINX_LINK"
                    log_success "Симлинк удалён"
                fi
                
                # Перезапуск nginx
                log_info "Перезапуск nginx"
                systemctl reload nginx 2>/dev/null || true
            fi
            
            # 4. Удаление порта из SSH
            SSH_CONFIG="/etc/ssh/sshd_config"
            if grep -q "^Port $PREV_SSH_PORT" "$SSH_CONFIG" 2>/dev/null; then
                log_info "Удаление порта $PREV_SSH_PORT из SSH конфигурации"
                sed -i "/^Port $PREV_SSH_PORT/d" "$SSH_CONFIG"
                systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
                log_success "Порт $PREV_SSH_PORT удалён из SSH"
            fi
            
            # 5. Удаление правил фаервола
            if command -v ufw &> /dev/null; then
                log_info "Удаление правил UFW"
                ufw delete allow $PREV_SSH_PORT/tcp 2>/dev/null || true
                ufw delete allow 80/tcp 2>/dev/null || true
                ufw delete allow 443/tcp 2>/dev/null || true
                log_success "Правила UFW удалены"
            elif command -v firewall-cmd &> /dev/null; then
                log_info "Удаление правил firewalld"
                firewall-cmd --permanent --remove-port=$PREV_SSH_PORT/tcp 2>/dev/null || true
                firewall-cmd --permanent --remove-service=http 2>/dev/null || true
                firewall-cmd --permanent --remove-service=https 2>/dev/null || true
                firewall-cmd --reload 2>/dev/null || true
                log_success "Правила firewalld удалены"
            fi
            
            # 6. Удаление логов nginx
            if [[ -n "$PREV_DOMAIN" ]]; then
                log_info "Удаление логов nginx"
                rm -f /var/log/nginx/${PREV_DOMAIN}_access.log 2>/dev/null || true
                rm -f /var/log/nginx/${PREV_DOMAIN}_error.log 2>/dev/null || true
            fi
            
            # 7. Удаление метки
            log_info "Удаление метки установки"
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

while true; do
    read -p "🌐 Введите домен для загрузки файлов: " MEDIA_DOMAIN < /dev/tty
    MEDIA_DOMAIN=$(echo "$MEDIA_DOMAIN" | xargs | sed 's|https\?://||' | sed 's|/$||')
    
    # Проверка на пустой ввод
    if [[ -z "$MEDIA_DOMAIN" ]]; then
        log_error "Домен не может быть пустым. Попробуйте снова."
        continue
    fi
    
    # Проверка на наличие точки в домене
    if [[ ! "$MEDIA_DOMAIN" =~ \. ]]; then
        log_error "Неверный формат домена. Домен должен содержать точку (например, media.norest.art). Попробуйте снова."
        continue
    fi
    
    # Проверка на недопустимые символы
    if [[ ! "$MEDIA_DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]]; then
        log_error "Домен содержит недопустимые символы. Используйте только буквы, цифры, точки и дефисы."
        continue
    fi
    
    # Все проверки пройдены
    break
done

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

# === ШАГ 4: Ввод SSH порта ===
log_step "Шаг 4: Настройка SSH-порта"
read -p "🔌 Введите порт для SSH-подключения [по-умолачнию 6934]: " SSH_PORT < /dev/tty
SSH_PORT=${SSH_PORT:-6934}

# Валидация порта
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [[ "$SSH_PORT" -lt 1 ]] || [[ "$SSH_PORT" -gt 65535 ]]; then
    log_error "Неверный номер порта. Должен быть от 1 до 65535"
    exit 1
fi

# Проверка на стандартные порты
if [[ "$SSH_PORT" == "22" ]]; then
    log_warn "Порт 22 — стандартный SSH порт. Убедитесь, что это intentional."
fi

log_success "SSH порт: $SSH_PORT"

# === ШАГ 5: Установка зависимостей ===
log_step "Шаг 5: Установка необходимых пакетов"
log_info "Запускаем обновление репозиториев и установку пакетов..."
echo "   Пакеты: nginx, openssh-server, curl, wget, ufw/firewalld, certbot, python3-certbot-nginx"
echo ""

case $OS_ID in
    ubuntu|debian)
        log_info "Выполнение: apt-get update"
        apt-get update
        echo ""
        log_info "Выполнение: apt-get install -y nginx openssh-server curl wget ufw certbot python3-certbot-nginx"
        apt-get install -y nginx openssh-server curl wget ufw certbot python3-certbot-nginx
        ;;
    centos|rhel|fedora|almalinux|rocky)
        if command -v dnf &> /dev/null; then
            log_info "Выполнение: dnf install -y nginx openssh-server curl wget firewalld certbot"
            dnf install -y nginx openssh-server curl wget firewalld certbot
        else
            log_info "Выполнение: yum install -y nginx openssh-server curl wget firewalld certbot"
            yum install -y nginx openssh-server curl wget firewalld certbot
        fi
        ;;
    *)
        log_warn "Неизвестная ОС: $OS_ID"
        log_info "Попытка установки через доступные менеджеры..."
        if command -v apt-get &> /dev/null; then
            apt-get update && apt-get install -y nginx openssh-server curl wget certbot python3-certbot-nginx
        elif command -v yum &> /dev/null; then
            yum install -y nginx openssh-server curl wget certbot
        elif command -v dnf &> /dev/null; then
            dnf install -y nginx openssh-server curl wget certbot
        else
            log_error "Не удалось установить пакеты автоматически."
            log_error "Установите вручную: nginx, openssh-server, curl, wget, certbot"
            exit 1
        fi
        ;;
esac

log_success "Пакеты установлены"

# === ШАГ 6: Создание пользователя ===
log_step "Шаг 6: Создание пользователя $UPLOAD_USER"
if id "$UPLOAD_USER" &>/dev/null; then
    log_warn "Пользователь $UPLOAD_USER уже существует — пропускаем создание"
else
    log_info "Выполнение: useradd -m -s /bin/bash -G www-data $UPLOAD_USER"
    useradd -m -s /bin/bash -G www-data "$UPLOAD_USER" 2>/dev/null || \
    useradd -m -s /bin/bash "$UPLOAD_USER"
    log_success "Пользователь $UPLOAD_USER создан"
fi

# === ШАГ 7: Настройка SSH ключа ===
log_step "Шаг 7: Настройка SSH-доступа"
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

# Настройка SSH-сервера на указанный порт
log_info "Проверка конфигурации SSH (/etc/ssh/sshd_config)"
SSH_CONFIG="/etc/ssh/sshd_config"
if ! grep -q "^Port $SSH_PORT" "$SSH_CONFIG" 2>/dev/null; then
    log_info "Добавление строки: Port $SSH_PORT"
    sed -i "/^#Port 22/a Port $SSH_PORT" "$SSH_CONFIG" 2>/dev/null || echo "Port $SSH_PORT" >> "$SSH_CONFIG"
    sed -i 's/^#PubkeyAuthentication yes/PubkeyAuthentication yes/' "$SSH_CONFIG" 2>/dev/null || true
    sed -i 's/^PubkeyAuthentication no/PubkeyAuthentication yes/' "$SSH_CONFIG" 2>/dev/null || true
    log_success "Порт $SSH_PORT добавлен в конфигурацию SSH"
else
    log_warn "Порт $SSH_PORT уже указан в конфигурации"
fi

log_info "Перезапуск SSH-сервиса"
systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
log_success "SSH-сервис перезапущен"

# === ШАГ 8: Настройка папки для загрузок ===
log_step "Шаг 8: Создание папки для загрузок"
UPLOAD_DIR="/var/www/uploads"
log_info "Создание директории: $UPLOAD_DIR"
mkdir -p "$UPLOAD_DIR"

log_info "Настройка прав: chown -R $UPLOAD_USER:$UPLOAD_USER $UPLOAD_DIR"
chown -R "$UPLOAD_USER:$UPLOAD_USER" "$UPLOAD_DIR"
chmod 755 "$UPLOAD_DIR"
log_success "Папка $UPLOAD_DIR готова"

# === ШАГ 9: Настройка nginx ===
log_step "Шаг 9: Настройка nginx для домена $MEDIA_DOMAIN"
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

# === ШАГ 10: Настройка фаервола ===
log_step "Шаг 10: Настройка фаервола"
if command -v ufw &> /dev/null; then
    log_info "UFW обнаружен — добавляем правила"
    echo "   ufw allow 22/tcp"
    ufw allow 22/tcp 2>/dev/null || true
    echo "   ufw allow $SSH_PORT/tcp"
    ufw allow $SSH_PORT/tcp 2>/dev/null || true
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
    echo "   firewall-cmd --permanent --add-port=$SSH_PORT/tcp"
    firewall-cmd --permanent --add-port=$SSH_PORT/tcp 2>/dev/null || true
    echo "   firewall-cmd --permanent --add-service=http"
    firewall-cmd --permanent --add-service=http 2>/dev/null || true
    echo "   firewall-cmd --permanent --add-service=https"
    firewall-cmd --permanent --add-service=https 2>/dev/null || true
    echo "   firewall-cmd --reload"
    firewall-cmd --reload 2>/dev/null || true
    log_success "Правила firewalld применены"
else
    log_warn "Фаервол не обнаружен"
    log_info "Вручную откройте порты: 22, $SSH_PORT, 80, 443"
fi

# === ШАГ 11: Финальная настройка прав ===
log_step "Шаг 11: Финальная настройка прав доступа"
log_info "chmod 775 $UPLOAD_DIR"
chmod 775 "$UPLOAD_DIR"
log_info "setfacl -m u:$UPLOAD_USER:rwx $UPLOAD_DIR"
setfacl -m u:"$UPLOAD_USER":rwx "$UPLOAD_DIR" 2>/dev/null || true
log_success "Права доступа настроены"

# === ШАГ 12: Тестовый файл ===
log_step "Шаг 12: Создание тестового файла"
TEST_FILE="$UPLOAD_DIR/test_keymaster.txt"
echo "KeyMaster server is ready! $(date)" > "$TEST_FILE"
chown "$UPLOAD_USER:$UPLOAD_USER" "$TEST_FILE"
log_success "Тестовый файл создан: $TEST_FILE"

# === ШАГ 13: Создание метки установки ===
log_step "Шаг 13: Создание метки установки"
log_info "Создание файла-метки: $MARKER_FILE"
cat > "$MARKER_FILE" << EOF
INSTALLED_AT=$(date '+%Y-%m-%d %H:%M:%S')
SCRIPT_VERSION=$SCRIPT_VERSION
DOMAIN=$MEDIA_DOMAIN
USER=$UPLOAD_USER
UPLOAD_DIR=$UPLOAD_DIR
SSH_PORT=$SSH_PORT
EOF
chmod 644 "$MARKER_FILE"
log_success "Метка установки создана"

# === ШАГ 14: Итоговая информация ===
log_step "✅ Настройка завершена!"
echo "╔════════════════════════════════════════════════════╗"
echo "║  🎉 Сервер KeyMaster готов к работе!              ║"
echo "╚════════════════════════════════════════════════════╝"
echo ""
echo "📋 Параметры подключения:"
echo "   • Домен медиа:      ${MEDIA_DOMAIN:-не указан}"
echo "   • Пользователь:     $UPLOAD_USER"
echo "   • SSH порт:         $SSH_PORT"
echo "   • Папка загрузок:   $UPLOAD_DIR"
echo "   • Веб-доступ:       http://${MEDIA_DOMAIN:-<IP-адрес>}/filename.jpg"
echo ""
echo "🔗 Пример для скрипта KeyMaster:"
echo "   media_domain = \"https://${MEDIA_DOMAIN:-<ваш-домен>}\""
echo "   server_port = $SSH_PORT"
echo "   username = \"$UPLOAD_USER\""
echo "   remote_folder = \"$UPLOAD_DIR\""
echo ""
echo "🧪 Быстрая проверка:"
if [[ -n "$MEDIA_DOMAIN" ]]; then
    echo "   1. SSH: ssh -p $SSH_PORT $UPLOAD_USER@$(hostname -I | awk '{print $1}' | head -1)"
    echo "   2. HTTP: curl -I http://$MEDIA_DOMAIN/test_keymaster.txt"
else
    echo "   1. SSH: ssh -p $SSH_PORT $UPLOAD_USER@$(hostname -I | awk '{print $1}' | head -1)"
    echo "   2. HTTP: curl -I http://$(hostname -I | awk '{print $1}')/test_keymaster.txt"
fi
echo ""

# 🔐 Рекомендация по HTTPS
if [[ -n "$MEDIA_DOMAIN" ]]; then
    echo -e "${YELLOW}🔒 HTTPS (рекомендуется для продакшена):${NC}"
    echo ""
    echo "   Certbot уже установлен! Для получения SSL-сертификата выполните:"
    echo ""
    echo -e "   ${GREEN}certbot --nginx -d $MEDIA_DOMAIN${NC}"
    echo ""
    echo "   Это автоматически:"
    echo "   ✅ Получит бесплатный сертификат Let's Encrypt"
    echo "   ✅ Настроит редирект HTTP → HTTPS"
    echo "   ✅ Добавит автообновление сертификата"
    echo ""
    echo "   Проверка автообновления:"
    echo -e "   ${CYAN}certbot renew --dry-run${NC}"
    echo ""
else
    echo -e "${YELLOW}🔒 HTTPS:${NC}"
    echo "   Для настройки HTTPS укажите домен при следующем запуске."
    echo "   Certbot уже установлен и готов к работе."
    echo ""
fi

# 🗑️ Информация об откате
echo -e "${YELLOW}🔄 Для отката выполенных команд - перезапустите скрипт:${NC}"
echo ""

log_success "Готово! Сервер ожидает подключения от скрипта KeyMaster 🚀"
echo ""
