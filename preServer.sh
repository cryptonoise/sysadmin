#!/bin/bash
#curl -fsSL https://raw.githubusercontent.com/cryptonoise/sysadmin/refs/heads/main/preServer.sh | sudo bash

set -euo pipefail

# Открываем дескриптор 3 для чтения с терминала (клавиатуры)
exec 3</dev/tty

# Функция безопасного чтения с /dev/tty
safe_read() {
    local prompt="$1"
    local varname="$2"
    printf "%s" "$prompt" > /dev/tty
    IFS= read -r "$varname" <&3
}

# === Блок 1: Приветствие и инициализация ===
SCRIPT_NAME="Linux Server Pre-Config"
SCRIPT_VERSION="1.6.3"
SCRIPT_DESC="Предварительная настройка Linux сервера"

# Метка запуска
MARKER_DIR="/var/lib/preserver"
MARKER_FILE="$MARKER_DIR/.preserver-ran"

clear

printf "\n"
printf "════════════════════════════════════════════\n"
printf "  %s\n" "$SCRIPT_NAME"
printf "  Версия: %s\n" "$SCRIPT_VERSION"
printf "  %s\n" "$SCRIPT_DESC"
printf "════════════════════════════════════════════\n"

printf "\nНажмите Enter чтобы начать..."
safe_read "" DUMMY_INPUT

printf "\n🚀  Начинаю базовую настройку безопасности сервера...\n\n"

export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none

# === Блок 2: Проверка и восстановление dpkg при сбоях ===
printf "🔧  Проверка целостности пакетной базы...\n"
echo "──────────────────────────────────────"
if [ -d /var/lib/dpkg/updates ] && ls /var/lib/dpkg/updates/* >/dev/null 2>&1; then
    printf "⚠️  Обнаружены следы прерванной установки. Восстанавливаю систему...\n"
    rm -f /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend
    rm -f /var/cache/apt/archives/lock /var/lib/apt/lists/lock
    dpkg --configure -a --force-confdef --force-confold || true
    rm -f /var/lib/dpkg/updates/*
    dpkg --configure -a || true
    printf "✅  Восстановление завершено.\n\n"
else
    printf "✅  Пакетная база в порядке.\n\n"
fi

# === Блок 3: Обновление системы ===
printf "🔄  Обновление системы...\n"
echo "──────────────────────────────────────"
echo "• Обновление списка пакетов..."
apt-get update -qq

echo "• Обновление установленных пакетов..."
apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"

echo "• Полное обновление дистрибутива..."
apt-get dist-upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"

echo "• Удаление ненужных зависимостей..."
apt-get autoremove -y

printf "✅  Система успешно обновлена!\n\n"

# === Блок 4: Установка необходимых утилит ===
printf "📦  Установка полезных утилит...\n"
echo "──────────────────────────────────────"
PACKAGES=("unattended-upgrades" "fail2ban" "htop" "iotop" "nethogs" "curl" "wget" "git" "cron")

for pkg in "${PACKAGES[@]}"; do
    if ! dpkg -s "$pkg" &>/dev/null; then
        echo "• Устанавливаем $pkg..."
        apt-get install -y --no-install-recommends "$pkg"
    else
        echo "• Пакет $pkg уже установлен"
    fi
done

printf "• Включаем и запускаем fail2ban...\n"
systemctl enable fail2ban >/dev/null 2>&1 || true
systemctl start fail2ban >/dev/null 2>&1 || true

printf "• Включаем и запускаем cron...\n"
systemctl enable cron >/dev/null 2>&1 || true
systemctl start cron >/dev/null 2>&1 || true

printf "✅  Утилиты установлены.\n\n"

# === Блок 5: Настройка SSH (Порт и Ключи) ===
printf "🔐  Настройка SSH...\n"
echo "──────────────────────────────────────"

SSH_CONFIG="/etc/ssh/sshd_config"
DEFAULT_PORT=1119
SSH_PORT=""

# 1. Запрос порта
while true; do
    safe_read "Введите порт SSH (по умолчанию $DEFAULT_PORT): " INPUT_PORT
    SSH_PORT=${INPUT_PORT:-$DEFAULT_PORT}
    
    if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]]; then
        printf "❌  Ошибка: Порт должен быть числом.\n"
        continue
    fi
    
    if [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
        printf "❌  Ошибка: Порт должен быть в диапазоне 1-65535.\n"
        continue
    fi
    
    if command -v ss &>/dev/null; then
        if ss -tuln | grep -q ":${SSH_PORT} "; then
            printf "⚠️  Порт $SSH_PORT уже занят другим сервисом.\n"
            safe_read "Продолжить использование этого порта? (y/N): " confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                continue
            fi
        fi
    fi
    
    break
done
printf "✅  Выбран порт SSH: %s\n" "$SSH_PORT"

# 2. Запрос SSH ключа
SSH_KEY_INPUT=""
while true; do
    safe_read "Введите SSH публичный ключ (начинается с ssh-rsa...): " SSH_KEY_INPUT
    
    if [ -z "$SSH_KEY_INPUT" ]; then
        printf "❌  Ошибка: Ключ не может быть пустым.\n"
        continue
    fi
    
    if [[ "$SSH_KEY_INPUT" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)\  ]]; then
        break
    else
        printf "❌  Ошибка: Неверный формат ключа. Он должен начинаться с типа ключа (например, ssh-rsa или ssh-ed25519).\n"
        printf "   Пример: ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI...\n"
    fi
done
printf "✅  Ключ принят.\n"

# 3. Применение настроек SSH
if [[ -f "$SSH_CONFIG" ]]; then
    cp "$SSH_CONFIG" "${SSH_CONFIG}.bak.$(date +%s)"
    
    if grep -q "^#Port" "$SSH_CONFIG" || grep -q "^Port" "$SSH_CONFIG"; then
        sed -i "s/^#\?Port.*/Port $SSH_PORT/" "$SSH_CONFIG"
    else
        echo "Port $SSH_PORT" >> "$SSH_CONFIG"
    fi
    
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' "$SSH_CONFIG"
    sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSH_CONFIG"
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$SSH_CONFIG"
    sed -i 's/^#\?UseDNS.*/UseDNS no/' "$SSH_CONFIG"
    
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    
    if ! grep -qF "$SSH_KEY_INPUT" /root/.ssh/authorized_keys 2>/dev/null; then
        echo "$SSH_KEY_INPUT" >> /root/.ssh/authorized_keys
        chmod 600 /root/.ssh/authorized_keys
        printf "✅  Ключ добавлен в /root/.ssh/authorized_keys\n"
    else
        printf "ℹ️  Такой ключ уже существует в authorized_keys\n"
    fi
    
    printf "• Перезапуск SSH сервиса...\n"
    
    SSH_SERVICE="ssh"
    if systemctl list-unit-files | grep -q "sshd.service"; then
        SSH_SERVICE="sshd"
    fi
    
    if sshd -t; then
        if systemctl restart "$SSH_SERVICE" 2>/dev/null; then
            printf "✅  SSH настроен и перезапущен на порту %s (служба: %s)\n" "$SSH_PORT" "$SSH_SERVICE"
        else
            if [ "$SSH_SERVICE" = "ssh" ]; then
                ALT_SERVICE="sshd"
            else
                ALT_SERVICE="ssh"
            fi
            
            if systemctl restart "$ALT_SERVICE" 2>/dev/null; then
                 printf "✅  SSH настроен и перезапущен на порту %s (служба: %s)\n" "$SSH_PORT" "$ALT_SERVICE"
            else
                 printf "⚠️  Не удалось автоматически перезапустить SSH. Пожалуйста, проверьте настройки и перезагрузите сервер вручную.\n"
            fi
        fi
    else
        printf "❌  Ошибка в конфигурации SSH. Перезапуск отменен. Проверьте ${SSH_CONFIG}\n"
        exit 1
    fi
else
    printf "❌  Файл конфигурации SSH не найден!\n"
    exit 1
fi

# === Блок 6: Настройка автоматических обновлений (Cron) ===
printf "\n📅  Настройка ежедневных обновлений...\n"
echo "──────────────────────────────────────"

CRON_FILE="/etc/cron.d/daily-security-update"
LOG_FILE="/var/log/auto-update.log"
UPDATE_SCRIPT="/usr/local/sbin/daily-security-update.sh"
TASK_NAME="daily-security-update"

# Скрипт-обёртка: переменные раскрываются здесь, весь вывод логируется
cat > "$UPDATE_SCRIPT" << 'EOF'
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
LOG_FILE="/var/log/auto-update.log"
{
    echo "===== $(date '+%F %T') start ====="
    apt-get update -qq
    apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
    apt-get autoremove -y
    echo "===== $(date '+%F %T') done ====="
} >> "$LOG_FILE" 2>&1
EOF
chmod 0755 "$UPDATE_SCRIPT"

cat > "$CRON_FILE" << EOF
# Название задачи: $TASK_NAME
# Расписание: Ежедневно в 03:00
# Действия: apt-get update / upgrade / autoremove
# Логирование: $LOG_FILE
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 3 * * * root $UPDATE_SCRIPT
EOF

chmod 0644 "$CRON_FILE"

# Cron сам подхватывает файлы из /etc/cron.d, но убедимся, что сервис запущен.
if ! systemctl is-active --quiet cron; then
    systemctl start cron
fi

printf "✅  Задача '%s' добавлена: обновление каждый день в 03:00.\n" "$TASK_NAME"
printf "   • Что делается: update, upgrade, autoremove\n"
printf "   • Скрипт: %s\n" "$UPDATE_SCRIPT"
printf "   • Лог файл: %s\n\n" "$LOG_FILE"

# === Блок 7: Итоговая информация ===
printf "\n✅  Готово! Сервер предварительно настроен.\n"
printf "   • Порт SSH: %s\n" "$SSH_PORT"
printf "   • Root-доступ: Разрешен (только по ключу)\n"
printf "   • Вход по паролю: Отключен\n"
printf "   • Fail2ban: Активен\n"
printf "   • Автообновления: Включены (ежедневно в 03:00)\n\n"

printf "⚠️  ВАЖНО: Не закрывайте текущее соединение, пока не проверите вход по новому порту в другом окне!\n"
printf "   Команда для проверки: ssh -p %s root@<IP_СЕРВЕРА>\n\n" "$SSH_PORT"

# === Установка метки запуска ===
mkdir -p "$MARKER_DIR"
{
    echo "version=$SCRIPT_VERSION"
    echo "ran_at=$(date '+%F %T')"
    echo "ssh_port=$SSH_PORT"
} > "$MARKER_FILE"
chmod 0644 "$MARKER_FILE"
printf "🏷️   Метка запуска установлена: %s\n\n" "$MARKER_FILE"

# === Блок 8: Перезагрузка ===
if [ -t 1 ] && [ -e /dev/tty ]; then
    safe_read "🔄  Перезагрузить сервер сейчас? [y/N]: " response
    case "$response" in
        [yY]|[yY][eE][sS])
            echo
            echo "🔁  Перезагрузка запущена..."
            reboot
            ;;
        *)
            echo
            echo "⏹  Перезагрузка отменена. Не забудьте перезагрузиться позже вручную."
            ;;
    esac
else
    echo "ℹ️  Неинтерактивный режим: пропуск запроса на перезагрузку."
    echo "   Чтобы перезагрузить вручную, выполните: sudo reboot"
fi
