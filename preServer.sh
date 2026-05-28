#!/bin/bash

set -euo pipefail

# Открываем дескриптор 3 для чтения с терминала (клавиатуры)
# Это позволяет работать интерактивно даже при запуске: curl ... | bash
exec 3</dev/tty

# Функция безопасного чтения с /dev/tty
safe_read() {
    local prompt="$1"
    local varname="$2"

    # Выводим приглашение прямо в терминал
    printf "%s" "$prompt" > /dev/tty

    # Читаем ввод из дескриптора 3 (клавиатура), а не из stdin (pipe)
    IFS= read -r "$varname" <&3
}

# === Блок 1: Приветствие и инициализация ===
SCRIPT_NAME="Linux Server Pre-Config"
SCRIPT_VERSION="1.5.0"
SCRIPT_DESC="Предварительная настройка Linux сервера"

# Очистка экрана
clear

# Вывод заголовка с линиями
printf "\n"
printf "════════════════════════════════════════════\n"
printf "  %s\n" "$SCRIPT_NAME"
printf "  Версия: %s\n" "$SCRIPT_VERSION"
printf "  %s\n" "$SCRIPT_DESC"
printf "════════════════════════════════════════════\n"

printf "\nНажмите Enter чтобы начать..."

# Ждем нажатия Enter через safe_read
safe_read "" DUMMY_INPUT

printf "\n🚀  Начинаю базовую настройку безопасности сервера...\n\n"

export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none

# === Блок 2: Проверка и восстановление dpkg при сбоях ===
printf "🔧  Проверка целостности пакетной базы...\n"
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
echo "──────────────────────────────────────"
echo "• Обновление установленных пакетов..."
apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
echo "──────────────────────────────────────"
echo "• Полное обновление дистрибутива..."
apt-get dist-upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
echo "──────────────────────────────────────"
echo "• Удаление ненужных зависимостей..."
apt-get autoremove -y
echo "──────────────────────────────────────"
printf "✅  Система успешно обновлена!\n\n"

# === Блок 4: Установка необходимых утилит ===
printf "📦  Установка полезных утилит...\n"
echo "──────────────────────────────────────"
PACKAGES=("unattended-upgrades" "fail2ban" "htop" "iotop" "nethogs" "curl" "wget" "git")

for pkg in "${PACKAGES[@]}"; do
    if ! dpkg -s "$pkg" &>/dev/null; then
        echo "• Устанавливаем $pkg..."
        apt-get install -y --no-install-recommends "$pkg"
    else
        echo "• Пакет $pkg уже установлен"
    fi
    echo "──────────────────────────────────────"
done

printf "• Включаем и запускаем fail2ban...\n"
systemctl enable fail2ban || true
systemctl start fail2ban || true
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
    
    # Проверка, что это число
    if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]]; then
        printf "❌  Ошибка: Порт должен быть числом.\n"
        continue
    fi
    
    # Проверка диапазона портов
    if [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
        printf "❌  Ошибка: Порт должен быть в диапазоне 1-65535.\n"
        continue
    fi
    
    # Проверка занятости порта (опционально, но полезно)
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
echo "──────────────────────────────────────"

# 2. Запрос SSH ключа
SSH_KEY_INPUT=""
while true; do
    safe_read "Введите SSH публичный ключ (начинается с ssh-rsa...): " SSH_KEY_INPUT
    
    if [ -z "$SSH_KEY_INPUT" ]; then
        printf "❌  Ошибка: Ключ не может быть пустым.\n"
        continue
    fi
    
    # Базовая проверка формата (начинается с типа ключа)
    if [[ "$SSH_KEY_INPUT" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)\  ]]; then
        break
    else
        printf "❌  Ошибка: Неверный формат ключа. Он должен начинаться с типа ключа (например, ssh-rsa или ssh-ed25519).\n"
        printf "   Пример: ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI...\n"
    fi
done
printf "✅  Ключ принят.\n"
echo "──────────────────────────────────────"

# 3. Применение настроек SSH
if [[ -f "$SSH_CONFIG" ]]; then
    # Резервная копия
    cp "$SSH_CONFIG" "${SSH_CONFIG}.bak.$(date +%s)"
    
    # Изменение порта
    if grep -q "^#Port" "$SSH_CONFIG" || grep -q "^Port" "$SSH_CONFIG"; then
        sed -i "s/^#\?Port.*/Port $SSH_PORT/" "$SSH_CONFIG"
    else
        echo "Port $SSH_PORT" >> "$SSH_CONFIG"
    fi
    
    # Настройки доступа
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' "$SSH_CONFIG"
    sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSH_CONFIG"
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$SSH_CONFIG" # Отключаем пароли для безопасности, так как есть ключ
    sed -i 's/^#\?UseDNS.*/UseDNS no/' "$SSH_CONFIG" # Ускоряет вход
    
    # Добавление ключа пользователю root
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    # Добавляем ключ, если его еще нет
    if ! grep -qF "$SSH_KEY_INPUT" /root/.ssh/authorized_keys 2>/dev/null; then
        echo "$SSH_KEY_INPUT" >> /root/.ssh/authorized_keys
        chmod 600 /root/.ssh/authorized_keys
        printf "✅  Ключ добавлен в /root/.ssh/authorized_keys\n"
    else
        printf "ℹ️  Такой ключ уже существует в authorized_keys\n"
    fi
    
    printf "• Перезапуск SSH сервиса...\n"
    # Проверка конфигурации перед перезапуском
    if sshd -t; then
        systemctl restart sshd || systemctl restart ssh
        printf "✅  SSH настроен и перезапущен на порту %s\n" "$SSH_PORT"
    else
        printf "❌  Ошибка в конфигурации SSH. Перезапуск отменен. Проверьте ${SSH_CONFIG}\n"
        exit 1
    fi
else
    printf "❌  Файл конфигурации SSH не найден!\n"
    exit 1
fi
echo "──────────────────────────────────────"

# === Блок 6: Итоговая информация ===
printf "\n✅  Готово! Сервер предварительно настроен.\n"
printf "   • Порт SSH: %s\n" "$SSH_PORT"
printf "   • Root-доступ: Разрешен (только по ключу)\n"
printf "   • Вход по паролю: Отключен\n"
printf "   • Fail2ban: Активен\n\n"

printf "⚠️  ВАЖНО: Не закрывайте текущее соединение, пока не проверите вход по новому порту в другом окне!\n"
printf "   Команда для проверки: ssh -p %s root@<IP_СЕРВЕРА>\n\n" "$SSH_PORT"

# === Блок 7: Перезагрузка ===
# Проверяем, есть ли у нас доступ к tty для вопроса о перезагрузке
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
