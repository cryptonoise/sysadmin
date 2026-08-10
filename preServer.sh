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
SCRIPT_VERSION="1.9.8"
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

# Убираем противоречащие настройки в drop-in конфигах (/etc/ssh/sshd_config.d/*.conf),
# т.к. Include стоит в начале sshd_config и sshd берёт ПЕРВОЕ встреченное значение —
# правки в основном файле иначе могут молча игнорироваться (частая причина потери доступа).
neutralize_sshd_dropins() {
    local f
    for f in /etc/ssh/sshd_config.d/*.conf; do
        [ -f "$f" ] || continue
        [ "$(basename "$f")" = "99-preserver.conf" ] && continue
        sed -i -E 's/^[[:space:]]*(Port|PermitRootLogin|PasswordAuthentication|PubkeyAuthentication)\b/# [preServer disabled] \1/' "$f"
        if ! grep -qE '^[^#[:space:]]' "$f" 2>/dev/null; then
            rm -f "$f"
            printf "🗑️  Удалён пустой drop-in конфиг: %s\n" "$f"
        fi
    done
}

disable_ssh_socket_activation() {
    if systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.socket'; then
        if systemctl is-enabled ssh.socket &>/dev/null || systemctl is-active ssh.socket &>/dev/null; then
            systemctl stop ssh.socket >/dev/null 2>&1 || true
            systemctl disable ssh.socket >/dev/null 2>&1 || true
            printf "ℹ️  Обнаружена socket activation (ssh.socket) — отключена, чтобы смена порта применялась без перезагрузки.\n"
        fi
    fi
}

verify_and_restart_sshd() {
    local want_port="$1" want_pwauth="$2" want_rootlogin="$3"

    # КРИТИЧНО: /run/sshd должен существовать ДО любого вызова sshd -T / sshd -t
    mkdir -p /run/sshd
    chmod 0755 /run/sshd

    local eff
    eff="$(sshd -T 2>&1)" || {
        printf "❌  sshd -T завершился с ошибкой, перезапуск отменён.\n"
        printf "    Вывод sshd -T:\n%s\n" "$eff"
        return 1
    }

    local eff_port eff_pwauth eff_rootlogin
    eff_port=$(awk '/^port /{print $2; exit}' <<< "$eff")
    eff_pwauth=$(awk '/^passwordauthentication /{print $2; exit}' <<< "$eff")
    eff_rootlogin=$(awk '/^permitrootlogin /{print $2; exit}' <<< "$eff")

    local norm_want_rootlogin="$want_rootlogin" norm_eff_rootlogin="$eff_rootlogin"
    [ "$norm_want_rootlogin" = "prohibit-password" ] && norm_want_rootlogin="without-password"
    [ "$norm_eff_rootlogin" = "prohibit-password" ] && norm_eff_rootlogin="without-password"

    if [ "$eff_port" != "$want_port" ] || [ "$eff_pwauth" != "$want_pwauth" ] || [ "$norm_eff_rootlogin" != "$norm_want_rootlogin" ]; then
        printf "❌  Эффективный конфиг sshd НЕ совпадает с ожидаемым (port=%s pwauth=%s rootlogin=%s).\n" "$eff_port" "$eff_pwauth" "$eff_rootlogin"
        printf "    Проверьте /etc/ssh/sshd_config.d/*.conf вручную. Перезапуск sshd ОТМЕНЁН.\n"
        return 1
    fi

    local svc="ssh"
    systemctl list-unit-files | grep -q "sshd.service" && svc="sshd"

    disable_ssh_socket_activation

    if ! sshd -t 2>&1; then
        printf "❌  sshd -t: синтаксическая ошибка, перезапуск отменён.\n"
        return 1
    fi

    systemctl enable "$svc" >/dev/null 2>&1 || true
    systemctl restart "$svc" 2>/dev/null || systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
    printf "✅  sshd перезапущен, эффективный конфиг подтверждён (port=%s pwauth=%s rootlogin=%s).\n" "$eff_port" "$eff_pwauth" "$eff_rootlogin"
    return 0
}

rollback_preserver() {
    local SSHD_CFG="/etc/ssh/sshd_config"
    printf "\n♻️   Откат настроек preServer...\n"
    echo "──────────────────────────────────────"

    if [ -f "$SSHD_CFG" ]; then
        cp "$SSHD_CFG" "${SSHD_CFG}.bak.$(date +%s)"
        neutralize_sshd_dropins

        if grep -qE '^\s*#?\s*Port\b' "$SSHD_CFG"; then
            sed -i -E 's/^\s*#?\s*Port\b.*/Port 22/' "$SSHD_CFG"
        else
            echo "Port 22" >> "$SSHD_CFG"
        fi
        sed -i -E 's/^\s*#?\s*PermitRootLogin\b.*/PermitRootLogin yes/' "$SSHD_CFG"
        sed -i -E 's/^\s*#?\s*PasswordAuthentication\b.*/PasswordAuthentication yes/' "$SSHD_CFG"
        sed -i -E 's/^\s*#?\s*PrintMotd\b.*/PrintMotd yes/' "$SSHD_CFG"
        sed -i -E 's/^\s*#?\s*PrintLastLog\b.*/PrintLastLog yes/' "$SSHD_CFG"

        if passwd -S root 2>/dev/null | awk '{print $2}' | grep -qE '^(L|LK|NP)$'; then
            printf "⚠️  У root не задан пароль. Вход по паролю не заработает без: passwd root\n"
        fi

        if command -v ufw &>/dev/null; then
            ufw allow 22/tcp comment 'SSH (preServer rollback)' >/dev/null 2>&1 || true
        fi

        verify_and_restart_sshd 22 yes yes || printf "⚠️  Порт/пароль отредактированы, но перезапуск не выполнен — проверьте вручную!\n"
    fi

    if dpkg -s fail2ban &>/dev/null; then
        systemctl stop fail2ban >/dev/null 2>&1 || true
        systemctl disable fail2ban >/dev/null 2>&1 || true
        apt-get purge -y fail2ban >/dev/null 2>&1 || true
        rm -f /etc/fail2ban/jail.local
        printf "✅  fail2ban удалён.\n"
    fi

    if dpkg -s fastfetch &>/dev/null; then
        apt-get purge -y fastfetch >/dev/null 2>&1 || true
        printf "✅  Fastfetch удалён.\n"
    elif command -v fastfetch &>/dev/null; then
        rm -f "$(command -v fastfetch)"
    fi
    rm -rf /root/.config/fastfetch
    rm -f /etc/profile.d/fastfetch-ssh.sh
    if [ -d /etc/update-motd.d ]; then
        chmod +x /etc/update-motd.d/* 2>/dev/null || true
    fi

    rm -f /usr/local/sbin/daily-security-update.sh
    rm -f /etc/cron.d/daily-security-update
    rm -f "$MARKER_FILE"

    printf "\n✅  Откат завершён.\n"
}

if [ -f "$MARKER_FILE" ]; then
    printf "\n⚠️  Обнаружена метка предыдущего запуска этого скрипта:\n"
    sed 's/^/     /' "$MARKER_FILE" > /dev/tty
    safe_read $'\nВыполнить откат настроек? (y/N): ' rerun_choice
    if [[ "$rerun_choice" =~ ^[Yy]$ ]]; then
        rollback_preserver
        exit 0
    else
        printf "⏹  Отменено пользователем.\n"
        exit 0
    fi
fi

printf "\nНажмите Enter чтобы начать..."
safe_read "" DUMMY_INPUT
printf "\n🚀  Начинаю базовую настройку безопасности сервера...\n"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
export APT_LISTCHANGES_FRONTEND=none
export PYTHONWARNINGS="ignore::SyntaxWarning"

# === Блок 2: Проверка dpkg ===
printf "🔧  Проверка целостности пакетной базы...\n"
echo "──────────────────────────────────────"
if [ -d /var/lib/dpkg/updates ] && ls /var/lib/dpkg/updates/* >/dev/null 2>&1; then
    printf "⚠️  Восстанавливаю систему...\n"
    rm -f /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock /var/lib/apt/lists/lock
    dpkg --configure -a --force-confdef --force-confold || true
    rm -f /var/lib/dpkg/updates/*
    dpkg --configure -a || true
fi
printf "✅  Пакетная база в порядке.\n"

# === Блок 3: Обновление системы ===
printf "🔄  Обновление системы...\n"
echo "──────────────────────────────────────"
apt-get update -qq
apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
apt-get dist-upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
apt-get autoremove -y
printf "✅  Система обновлена!\n"

# === Блок 4: Установка утилит ===
printf "📦  Установка утилит...\n"
echo "──────────────────────────────────────"
PACKAGES=("unattended-upgrades" "fail2ban" "htop" "iotop" "nethogs" "curl" "wget" "git" "cron" "ripgrep")
MISSING_PACKAGES=()
for pkg in "${PACKAGES[@]}"; do
    if ! dpkg -s "$pkg" &>/dev/null; then
        MISSING_PACKAGES+=("$pkg")
    fi
done
if [ "${#MISSING_PACKAGES[@]}" -gt 0 ]; then
    apt-get install -y --no-install-recommends "${MISSING_PACKAGES[@]}"
fi

mkdir -p /etc/fail2ban
cat > /etc/fail2ban/jail.local << 'F2BEOF'
[sshd]
enabled = true
port = 1119
backend = systemd
maxretry = 5
bantime = 1h
findtime = 10m
F2BEOF
systemctl enable fail2ban >/dev/null 2>&1 || true
systemctl restart fail2ban >/dev/null 2>&1 || true
systemctl enable cron >/dev/null 2>&1 || true
systemctl start cron >/dev/null 2>&1 || true
printf "✅  Утилиты установлены.\n"

# === Блок 5: Настройка SSH ===
printf "🔐  Настройка SSH...\n"
echo "──────────────────────────────────────"
SSH_CONFIG="/etc/ssh/sshd_config"
DEFAULT_PORT=1119
SSH_PORT=""
SKIP_SSH_SETUP=false

if command -v ss &>/dev/null; then
    if ss -tuln | grep -q ":${DEFAULT_PORT} "; then
        SKIP_SSH_SETUP=true
        SSH_PORT="skipped"
        printf "⚠️  Порт %s занят — настройка SSH пропущена.\n" "$DEFAULT_PORT"
    fi
fi

if [ "$SKIP_SSH_SETUP" = false ]; then
    while true; do
        safe_read "Введите порт SSH (по умолчанию $DEFAULT_PORT): " INPUT_PORT
        SSH_PORT=${INPUT_PORT:-$DEFAULT_PORT}
        if [[ "$SSH_PORT" =~ ^[0-9]+$ ]] && [ "$SSH_PORT" -ge 1 ] && [ "$SSH_PORT" -le 65535 ]; then
             if command -v ss &>/dev/null && ss -tuln | grep -q ":${SSH_PORT} "; then
                printf "\n⚠️  Порт %s занят.\n" "$SSH_PORT"
                safe_read "Продолжить? (y/N): " confirm
                [[ "$confirm" =~ ^[Yy]$ ]] && break || continue
            fi
            break
        else
            printf "\n❌  Ошибка: Порт должен быть числом 1-65535.\n"
        fi
    done
    printf "\n✅  Выбран порт SSH: %s\n" "$SSH_PORT"

    SSH_KEY_INPUT=""
    while true; do
        safe_read "Введите SSH публичный ключ: " SSH_KEY_INPUT
        if [[ "$SSH_KEY_INPUT" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)\  ]]; then
            break
        else
            printf "\n❌  Неверный формат ключа.\n"
        fi
    done
    printf "\n✅  Ключ принят.\n"

    if [[ -f "$SSH_CONFIG" ]]; then
        cp "$SSH_CONFIG" "${SSH_CONFIG}.bak.$(date +%s)"
        ls -1t ${SSH_CONFIG}.bak.* 2>/dev/null | tail -n +6 | xargs -r rm -f
        neutralize_sshd_dropins

        sed -i "s/^#\?Port.*/Port $SSH_PORT/" "$SSH_CONFIG"
        grep -q "^Port" "$SSH_CONFIG" || echo "Port $SSH_PORT" >> "$SSH_CONFIG"
        
        sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' "$SSH_CONFIG"
        sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSH_CONFIG"
        sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$SSH_CONFIG"
        sed -i 's/^#\?UseDNS.*/UseDNS no/' "$SSH_CONFIG"

        mkdir -p /root/.ssh && chmod 700 /root/.ssh
        grep -qF "$SSH_KEY_INPUT" /root/.ssh/authorized_keys 2>/dev/null || echo "$SSH_KEY_INPUT" >> /root/.ssh/authorized_keys
        chmod 600 /root/.ssh/authorized_keys

        # КРИТИЧНО: Создаём /run/sshd до проверок
        mkdir -p /run/sshd
        chmod 0755 /run/sshd

        if [ -f /etc/fail2ban/jail.local ]; then
            sed -i "s/^port = .*/port = $SSH_PORT/" /etc/fail2ban/jail.local
            systemctl restart fail2ban >/dev/null 2>&1 || true
        fi

        if command -v ufw &>/dev/null; then
            ufw allow "${SSH_PORT}/tcp" comment 'SSH (preServer)' >/dev/null 2>&1 || true
            printf "• Порт %s открыт в ufw\n" "$SSH_PORT"
        fi

        if ! verify_and_restart_sshd "$SSH_PORT" no prohibit-password; then
            printf "❌  Ошибка применения настроек SSH. Проверьте конфиги вручную.\n"
            exit 1
        fi
    fi
fi

# === Блок 6: Автообновления ===
printf "\n📅  Настройка автообновлений...\n"
UPDATE_SCRIPT="/usr/local/sbin/daily-security-update.sh"
cat > "$UPDATE_SCRIPT" << 'EOF'
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
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

cat > "/etc/cron.d/daily-security-update" << EOF
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 3 * * * root $UPDATE_SCRIPT
EOF
chmod 0644 "/etc/cron.d/daily-security-update"
systemctl is-active --quiet cron || systemctl start cron
printf "✅  Автообновления настроены (03:00 daily).\n"

# === Блок 7: Fastfetch ===
printf "\n🖥️  Установка Fastfetch...\n"
FASTFETCH_INSTALLED=false
if command -v fastfetch &>/dev/null; then
    FASTFETCH_INSTALLED=true
else
    if command -v add-apt-repository &>/dev/null; then
        add-apt-repository -y ppa:zhangsongcui3371/fastfetch >/dev/null 2>&1 && \
        apt-get update -qq && apt-get install -y fastfetch && FASTFETCH_INSTALLED=true || true
    fi
    if ! $FASTFETCH_INSTALLED; then
        ARCH=$(dpkg --print-architecture)
        FF_URL=$(curl -fsSL "https://api.github.com/repos/fastfetch-cli/fastfetch/releases/latest" | grep "browser_download_url" | grep "linux-${ARCH}.deb" | head -1 | cut -d '"' -f 4)
        if [ -n "$FF_URL" ]; then
            TMP_DEB=$(mktemp)
            curl -fsSL "$FF_URL" -o "$TMP_DEB"
            dpkg -i "$TMP_DEB" || apt-get install -f -y
            rm -f "$TMP_DEB"
            FASTFETCH_INSTALLED=true
        fi
    fi
fi

if $FASTFETCH_INSTALLED; then
    printf "• Настройка логотипа и конфига...\n"
    mkdir -p /root/.config/fastfetch

    # ГЕНЕРАЦИЯ ЛОГОТИПА ИЗ ТЕКСТОВОГО ФАЙЛА (ASCII ART)
    # Используем только ASCII символы (+, -, |), чтобы избежать проблем с шириной символов в терминале
    cat > /root/.config/fastfetch/logo.txt << 'ASCII_LOGO'
+------------------------------+
| +--------------------------+ |
| | +----------------------+ | |
| | | +------------------+ | | |
| | | | +--------------+ | | | |
| | | | | +----------+ | | | | |
| | | | | |          | | | | | |
| | | | | |    ++    | | | | | |
| | | | | |          | | | | | |
| | | | | +----------+ | | | | |
| | | | +--------------+ | | | |
| | | +------------------+ | | |
| | +----------------------+ | |
| +--------------------------+ |
+------------------------------+
ASCII_LOGO
    
    # Конфигурация fastfetch
    cat > /root/.config/fastfetch/config.jsonc << 'FFCONFIG'
{
    "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",
    "logo": {
        "type": "file",
        "source": "/root/.config/fastfetch/logo.txt",
        "color": "blue",
        "padding": { "top": 1, "left": 2, "right": 4 }
    },
    "display": {
        "color": { "keys": "blue", "title": "bright_magenta", "separator": "white" }
    },
    "modules": [
        { "type": "custom", "format": "\u001b[97m┌──────────────────────────────────────Hardware──────────────────────────────────────┐\u001b[0m" },
        { "type": "host", "key": "▣ PC : ", "keyColor": "green" },
        { "type": "cpu", "key": "   ├▢ CPU: ", "keyColor": "green" },
        { "type": "cpuusage", "key": "   ├▢ Usage: ", "keyColor": "green" },
        { "type": "loadavg", "key": "   ├▢ Load: ", "keyColor": "green" },
        { "type": "gpu", "key": "   ├▢ GPU: ", "keyColor": "green" },
        { "type": "memory", "key": "   ├▢ RAM: ", "keyColor": "green" },
        { "type": "swap", "key": "   ├▢ Swap: ", "keyColor": "green" },
        { "type": "disk", "key": "   ├▢ Disk: ", "keyColor": "green" },
        { "type": "custom", "format": "\u001b[97m└────────────────────────────────────────────────────────────────────────────────────┘\u001b[0m" },
        "break",
        { "type": "custom", "format": "\u001b[97m┌──────────────────────────────────────Software──────────────────────────────────────┐\u001b[0m" },
        { "type": "os", "key": "▣ OS : ", "keyColor": "yellow" },
        { "type": "kernel", "key": "   ├▢ Kernel: ", "keyColor": "yellow" },
        { "type": "packages", "key": "   ├▢ Packages: ", "keyColor": "yellow" },
        { "type": "shell", "key": "   ├▢ Shell: ", "keyColor": "yellow" },
        { "type": "custom", "format": "\u001b[97m└────────────────────────────────────────────────────────────────────────────────────┘\u001b[0m" },
        "break",
        { "type": "custom", "format": "\u001b[97m┌───────────────────────────────────────Network──────────────────────────────────────┐\u001b[0m" },
        { "type": "localip", "key": "▣ IP : ", "keyColor": "cyan" },
        { "type": "command", "key": "   └▢ Loc: ", "keyColor": "cyan", "text": "curl -s --max-time 2 https://ipinfo.io/city" },
        { "type": "custom", "format": "\u001b[97m└────────────────────────────────────────────────────────────────────────────────────┘\u001b[0m" },
        "break",
        { "type": "uptime", "key": "▣ UP : ", "keyColor": "magenta" },
        { "type": "datetime", "key": "   └⏰ : ", "keyColor": "magenta" },
        { "type": "colors", "paddingLeft": 2, "symbol": "circle" }
    ]
}
FFCONFIG

    # Отключение MOTD
    if [ -d /etc/update-motd.d ]; then
        chmod -x /etc/update-motd.d/* 2>/dev/null || true
    fi
    truncate -s 0 /etc/motd 2>/dev/null || true
    
    if grep -q "^PrintMotd" "$SSH_CONFIG" 2>/dev/null; then
        sed -i 's/^PrintMotd.*/PrintMotd no/' "$SSH_CONFIG"
    else
        echo "PrintMotd no" >> "$SSH_CONFIG"
    fi

    cat > /etc/profile.d/fastfetch-ssh.sh << 'PROFEOF'
if [ -n "${FASTFETCH_RAN:-}" ]; then return 0; fi
if [ -n "$SSH_CONNECTION" ] && command -v fastfetch >/dev/null 2>&1; then
    fastfetch
    export FASTFETCH_RAN=1
fi
PROFEOF
    chmod 0644 /etc/profile.d/fastfetch-ssh.sh
    printf "✅  Fastfetch настроен.\n"
fi

# === Блок 8: Финал ===
printf "\n✅  Готово!\n"
printf "   • Порт SSH: %s\n" "${SSH_PORT:-skipped}"
printf "   • Fail2ban: Active\n"
printf "   • Fastfetch: %s\n" "$($FASTFETCH_INSTALLED && echo 'Installed' || echo 'Skipped')"

mkdir -p "$MARKER_DIR"
echo "version=$SCRIPT_VERSION" > "$MARKER_FILE"
echo "ran_at=$(date '+%F %T')" >> "$MARKER_FILE"

if [ -t 1 ] && [ -e /dev/tty ]; then
    safe_read "🔄  Перезагрузить сейчас? [y/N]: " response
    [[ "$response" =~ ^[Yy]$ ]] && reboot
fi
