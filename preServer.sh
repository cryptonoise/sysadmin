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
SCRIPT_VERSION="1.9.2"
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
done
}
# Многие облачные образы Ubuntu (22.04+/24.04) используют systemd socket activation для SSH:
# юнит ssh.socket слушает порт, ЖЁСТКО прописанный в его unit-файле (обычно 22), независимо
# от значения Port в /etc/ssh/sshd_config. В этом режиме простой "systemctl restart ssh/sshd"
# НЕ меняет реально прослушиваемый порт — старый сокет остаётся открытым до перезагрузки
# (или до ручной правки ssh.socket). Поэтому переводим систему на классический режим,
# при котором sshd сам слушает порт из sshd_config — смена порта тогда применяется сразу.
disable_ssh_socket_activation() {
if systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.socket'; then
if systemctl is-enabled ssh.socket &>/dev/null || systemctl is-active ssh.socket &>/dev/null; then
systemctl stop ssh.socket >/dev/null 2>&1 || true
systemctl disable ssh.socket >/dev/null 2>&1 || true
printf "ℹ️  Обнаружена socket activation (ssh.socket) — отключена, чтобы смена порта применялась без перезагрузки.\n"
fi
fi
}
# Ждём, пока порт реально начнёт слушаться (контроль факта применения настроек).
wait_port() { # $1 = порт, $2 = таймаут в секундах
local p="$1" t="$2" i
for ((i=0; i<t*2; i++)); do
ss -tuln 2>/dev/null | grep -q ":${p} " && return 0
sleep 0.5
done
return 1
}
# Проверяем, что итоговые (effective) значения sshd реально совпадают с тем, что мы хотели.
# Если нет — НЕ перезапускаем sshd, чтобы не потерять доступ.
verify_and_restart_sshd() {
local want_port="$1" want_pwauth="$2" want_rootlogin="$3"
local eff
eff="$(sshd -T 2>/dev/null)" || { printf "❌  sshd -T завершился с ошибкой, перезапуск отменён.\n"; return 1; }
local eff_port eff_pwauth eff_rootlogin
eff_port=$(awk '/^port /{print $2; exit}' <<< "$eff")
eff_pwauth=$(awk '/^passwordauthentication /{print $2; exit}' <<< "$eff")
eff_rootlogin=$(awk '/^permitrootlogin /{print $2; exit}' <<< "$eff")
# sshd -T нормализует синонимы: prohibit-password == without-password
local norm_want_rootlogin="$want_rootlogin" norm_eff_rootlogin="$eff_rootlogin"
[ "$norm_want_rootlogin" = "prohibit-password" ] && norm_want_rootlogin="without-password"
[ "$norm_eff_rootlogin" = "prohibit-password" ] && norm_eff_rootlogin="without-password"
if [ "$eff_port" != "$want_port" ] || [ "$eff_pwauth" != "$want_pwauth" ] || [ "$norm_eff_rootlogin" != "$norm_want_rootlogin" ]; then
printf "❌  Эффективный конфиг sshd НЕ совпадает с ожидаемым (port=%s pwauth=%s rootlogin=%s).\n" "$eff_port" "$eff_pwauth" "$eff_rootlogin"
printf "    Проверьте /etc/ssh/sshd_config.d/*.conf вручную. Перезапуск sshd ОТМЕНЁН, старый сервис продолжает работать.\n"
return 1
fi
local svc="ssh"
systemctl list-unit-files | grep -q "sshd.service" && svc="sshd"
mkdir -p /run/sshd
disable_ssh_socket_activation
if ! sshd -t; then
printf "❌  sshd -t: синтаксическая ошибка, перезапуск отменён.\n"
return 1
fi
systemctl enable "$svc" >/dev/null 2>&1 || true
systemctl restart "$svc" >/dev/null 2>&1 || systemctl restart ssh >/dev/null 2>&1 || true
# Контроль: порт должен РЕАЛЬНО слушаться. На машинах, где ssh.socket остался
# живым (или был поднят между stop и restart), старый listen-сокет иначе живёт до ребута.
if command -v ss >/dev/null 2>&1; then
if ! wait_port "$want_port" 3; then
printf "⚠️  Порт %s не слушается после restart %s — гашу остатки socket activation и повторяю...\n" "$want_port" "$svc"
systemctl stop ssh.socket >/dev/null 2>&1 || true
systemctl disable ssh.socket >/dev/null 2>&1 || true
systemctl restart "$svc" >/dev/null 2>&1 || true
fi
if wait_port "$want_port" 3; then
printf "✅  sshd перезапущен, эффективный конфиг подтверждён (port=%s pwauth=%s rootlogin=%s), порт %s реально слушается.\n" "$eff_port" "$eff_pwauth" "$eff_rootlogin" "$want_port"
return 0
else
printf "❌  Порт %s так и не слушается. Выполните вручную:\n" "$want_port"
printf "    systemctl disable --now ssh.socket && systemctl restart %s\n" "$svc"
return 1
fi
fi
printf "✅  sshd перезапущен, эффективный конфиг подтверждён (port=%s pwauth=%s rootlogin=%s).\n" "$eff_port" "$eff_pwauth" "$eff_rootlogin"
return 0
}
# Функция отката настроек, сделанных этим скриптом.
# Софт (htop, iotop, nethogs, curl, wget, git, cron, ripgrep, unattended-upgrades)
# НЕ удаляется — трогаем только то, что специфично для этого скрипта.
# SSH-ключ (authorized_keys, PubkeyAuthentication) НЕ трогаем — только порт и пароль.
rollback_preserver() {
local SSHD_CFG="/etc/ssh/sshd_config"
printf "\n♻️   Откат настроек preServer...\n"
echo "──────────────────────────────────────"
# 1. SSH: порт обратно на 22, пароль обратно разрешаем, ключ не трогаем
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
# Если у root нет пароля (типично для VPS-образов с доступом только по ключу),
# PasswordAuthentication yes не поможет — аккаунт остаётся заблокирован.
if passwd -S root 2>/dev/null | awk '{print $2}' | grep -qE '^(L|LK|NP)$'; then
printf "⚠️  У root не задан пароль (аккаунт заблокирован/без пароля).\n"
printf "    Вход по паролю не заработает, пока вы не установите пароль: passwd root\n"
fi
if command -v ufw &>/dev/null; then
ufw allow 22/tcp comment 'SSH (preServer rollback)' >/dev/null 2>&1 || true
fi
verify_and_restart_sshd 22 yes yes || printf "⚠️  Порт/пароль отредактированы в файле, но перезапуск не выполнен автоматически — проверьте вручную!\n"
fi
# 2. Удаляем fail2ban
if dpkg -s fail2ban &>/dev/null; then
systemctl stop fail2ban >/dev/null 2>&1 || true
systemctl disable fail2ban >/dev/null 2>&1 || true
apt-get purge -y fail2ban >/dev/null 2>&1 || true
rm -f /etc/fail2ban/jail.local
printf "✅  fail2ban удалён.\n"
else
printf "ℹ️  fail2ban не установлен, пропуск.\n"
fi
# 3. Удаляем Fastfetch и его конфиги
if dpkg -s fastfetch &>/dev/null; then
apt-get purge -y fastfetch >/dev/null 2>&1 || true
printf "✅  Fastfetch удалён (apt).\n"
elif command -v fastfetch &>/dev/null; then
rm -f "$(command -v fastfetch)"
printf "✅  Fastfetch удалён (бинарник).\n"
else
printf "ℹ️  Fastfetch не установлен, пропуск.\n"
fi
rm -rf /root/.config/fastfetch
rm -f /etc/profile.d/fastfetch-ssh.sh
if [ -d /etc/update-motd.d ]; then
chmod +x /etc/update-motd.d/* 2>/dev/null || true
fi
# 4. Удаляем скрипт автообновления и его cron-задачу
rm -f /usr/local/sbin/daily-security-update.sh
rm -f /etc/cron.d/daily-security-update
printf "✅  Скрипт автообновления и его cron-задача удалены.\n"
# 5. Удаляем метку запуска
rm -f "$MARKER_FILE"
printf "\n✅  Откат завершён. Ключ доступа НЕ удалён. Остальной софт (htop, iotop, nethogs, git, ripgrep и т.д.) оставлен без изменений.\n"
}
if [ -f "$MARKER_FILE" ]; then
printf "\n⚠️  Обнаружена метка предыдущего запуска этого скрипта:\n"
sed 's/^/     /' "$MARKER_FILE" > /dev/tty
safe_read $'\nВыполнить откат настроек (SSH → порт 22 + пароль, удалить fail2ban и Fastfetch, удалить автообновления)? (y/N): ' rerun_choice
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
# Подавляем SyntaxWarning от python-скриптов пакетов (например fail2ban),
# которые байткомпилируются при установке и засоряют вывод
export PYTHONWARNINGS="ignore::SyntaxWarning"
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
printf "✅  Восстановление завершено.\n"
else
printf "✅  Пакетная база в порядке.\n"
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
printf "✅  Система успешно обновлена!\n"
# === Блок 4: Установка необходимых утилит ===
printf "📦  Установка полезных утилит...\n"
echo "──────────────────────────────────────"
PACKAGES=("unattended-upgrades" "fail2ban" "htop" "iotop" "nethogs" "curl" "wget" "git" "cron" "ripgrep")
MISSING_PACKAGES=()
for pkg in "${PACKAGES[@]}"; do
if ! dpkg -s "$pkg" &>/dev/null; then
MISSING_PACKAGES+=("$pkg")
else
echo "• Пакет $pkg уже установлен"
fi
done
if [ "${#MISSING_PACKAGES[@]}" -gt 0 ]; then
echo "• Устанавливаем: ${MISSING_PACKAGES[*]}"
apt-get install -y --no-install-recommends "${MISSING_PACKAGES[@]}"
fi
printf "• Настраиваем и запускаем fail2ban...\n"
# jail.conf по умолчанию не включает jail [sshd] (enabled=false) — без jail.local
# fail2ban формально работает, но никого не банит. Порт здесь пока дефолтный,
# после смены SSH-порта в блоке 5 конфиг будет обновлён на актуальный.
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
printf "• Включаем и запускаем cron...\n"
systemctl enable cron >/dev/null 2>&1 || true
systemctl start cron >/dev/null 2>&1 || true
printf "✅  Утилиты установлены.\n"
# === Блок 5: Настройка SSH (Порт и Ключи) ===
printf "🔐  Настройка SSH...\n"
echo "──────────────────────────────────────"
SSH_CONFIG="/etc/ssh/sshd_config"
DEFAULT_PORT=1119
SSH_PORT=""
SKIP_SSH_SETUP=false
# Если порт по умолчанию (1119) уже занят, предложим пропустить настройку SSH полностью
if command -v ss &>/dev/null; then
if ss -tuln | grep -q ":${DEFAULT_PORT} "; then
SKIP_SSH_SETUP=true
SSH_PORT="skipped"
printf "⚠️  Порт %s уже используется — настройка SSH (смена порта и добавление ключа) автоматически пропущена.\n" "$DEFAULT_PORT"
fi
fi
if [ "$SKIP_SSH_SETUP" = false ]; then
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
printf "⚠️  Порт %s уже занят другим сервисом.\n" "$SSH_PORT"
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
safe_read "Введите SSH публичный ключ (начинается с ssh-rsa/ssh-ed25519/...): " SSH_KEY_INPUT
if [ -z "$SSH_KEY_INPUT" ]; then
printf "❌  Ошибка: Ключ не может быть пустым.\n"
continue
fi
if [[ "$SSH_KEY_INPUT" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)\  ]]; then
break
else
printf "❌  Ошибка: Неверный формат ключа. Он должен начинаться с типа ключа (например, ssh-ed25519).\n"
printf "   Пример: ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI...\n"
fi
done
printf "✅  Ключ принят.\n"
# 3. Применение настроек SSH
if [[ -f "$SSH_CONFIG" ]]; then
cp "$SSH_CONFIG" "${SSH_CONFIG}.bak.$(date +%s)"
# Держим только последние 5 бэкапов, старые удаляем
ls -1t ${SSH_CONFIG}.bak.* 2>/dev/null | tail -n +6 | xargs -r rm -f
neutralize_sshd_dropins
if grep -q "^#Port" "$SSH_CONFIG" || grep -q "^Port" "$SSH_CONFIG"; then
sed -i "s/^#\?Port.*/Port $SSH_PORT/" "$SSH_CONFIG"
else
echo "Port $SSH_PORT" >> "$SSH_CONFIG"
fi
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' "$SSH_CONFIG"
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
# Обновляем порт в fail2ban под реальный выбранный SSH-порт
if [ -f /etc/fail2ban/jail.local ]; then
sed -i "s/^port = .*/port = $SSH_PORT/" /etc/fail2ban/jail.local
systemctl restart fail2ban >/dev/null 2>&1 || true
fi
# Открываем новый SSH-порт в ufw, если он установлен (чтобы не потерять доступ,
# если ufw будет включён позже без учёта нестандартного порта).
# Старый порт 22 НЕ закрываем автоматически.
if command -v ufw &>/dev/null; then
ufw allow "${SSH_PORT}/tcp" comment 'SSH (preServer)' >/dev/null 2>&1 || true
printf "• Порт %s открыт в ufw (правило добавлено, сам ufw не включается автоматически)\n" "$SSH_PORT"
fi
if verify_and_restart_sshd "$SSH_PORT" no prohibit-password; then
:
else
printf "❌  Настройки НЕ применены безопасно (эффективный конфиг не совпал или ошибка синтаксиса).\n"
printf "    Старый SSH продолжает работать на прежнем порту — проверьте %s и /etc/ssh/sshd_config.d/ вручную.\n" "$SSH_CONFIG"
exit 1
fi
else
printf "❌  Файл конфигурации SSH не найден!\n"
exit 1
fi
else
printf "ℹ️  Настройка SSH была пропущена пользователем.\n"
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
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
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
printf "   • Лог файл: %s\n" "$LOG_FILE"
# === Блок 7: Установка и настройка Fastfetch ===
printf "\n🖥️  Установка Fastfetch...\n"
echo "──────────────────────────────────────"
FASTFETCH_INSTALLED=false
if command -v fastfetch &>/dev/null; then
printf "ℹ️  Fastfetch уже установлен: $(fastfetch --version 2>/dev/null | head -1)\n"
FASTFETCH_INSTALLED=true
else
# Попытка 1: официальный PPA (Ubuntu/Debian)
if command -v add-apt-repository &>/dev/null; then
printf "• Добавляем PPA ppa:zhangsongcui3371/fastfetch...\n"
add-apt-repository -y ppa:zhangsongcui3371/fastfetch >/dev/null 2>&1 && \
apt-get update -qq && \
apt-get install -y --no-install-recommends fastfetch && \
FASTFETCH_INSTALLED=true || true
fi
# Попытка 2: скачать deb напрямую с GitHub (последний релиз)
if ! $FASTFETCH_INSTALLED; then
printf "• PPA недоступен, загружаю deb-пакет с GitHub...\n"
ARCH=$(dpkg --print-architecture)
FF_URL=$(curl -fsSL "https://api.github.com/repos/fastfetch-cli/fastfetch/releases/latest" \
| grep "browser_download_url" \
| grep "linux-${ARCH}.deb" \
| head -1 \
| cut -d '"' -f 4)
if [ -n "$FF_URL" ]; then
TMP_DEB=$(mktemp /tmp/fastfetch-XXXXXX.deb)
curl -fsSL "$FF_URL" -o "$TMP_DEB"
dpkg -i "$TMP_DEB" || apt-get install -f -y
rm -f "$TMP_DEB"
FASTFETCH_INSTALLED=true
fi
fi
if $FASTFETCH_INSTALLED; then
printf "✅  Fastfetch установлен: $(fastfetch --version 2>/dev/null | head -1)\n"
else
printf "⚠️  Не удалось установить Fastfetch — пропускаю настройку.\n"
fi
fi
# Конфигурация fastfetch
if $FASTFETCH_INSTALLED; then
printf "• Создаём конфигурацию fastfetch...\n"
mkdir -p /root/.config/fastfetch
# --- Логотип: отдельный файл, чтобы fastfetch рисовал его СЛЕВА,
# а все модули — отдельной колонкой справа (двухколоночный layout) ---
# Важно: \033/\u001b нужно записать РЕАЛЬНЫМ байтом ESC через printf —
# heredoc (в отличие от JSON) не раскрывает escape-последовательности.
{
printf '\033[94m'
cat << 'BOXART_TOP'
┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
┃ ┏━━━━━━━━━━━━━━━━━━━━━━━━━━┓ ┃
┃ ┃ ┏━━━━━━━━━━━━━━━━━━━━━━┓ ┃ ┃
┃ ┃ ┃ ┏━━━━━━━━━━━━━━━━━━┓ ┃ ┃ ┃
┃ ┃ ┃  ┏━━━━━━━━━━━━━━┓ ┃ ┃ ┃ ┃
┃ ┃ ┃  ┃ ┏━━━━━━━━━━ ┃ ┃ ┃  ┃
┃ ┃ ┃ ┃ ┃ ┃          ┃ ┃ ┃  ┃ ┃
BOXART_TOP
# Средняя строка с двумя зелёными точками-статусами (█──█ = скрипт настройки отработал).
# ВАЖНО 1: видимая длина строки (без ANSI-кодов) = 32 символа, как у остальных
# строк рамки, иначе правая часть рисунка "съезжает".
# ВАЖНО 2: используем ТОЛЬКО символы с фиксированной узкой шириной (box drawing
# и block elements). "●" (U+25CF) имеет Ambiguous width — часть терминалей рисует
# его шириной 2, и правая граница уезжает вправо.
# ВАЖНО 3: внутренняя ниша = 10 символов, контент = 4 (█──█) → отступы строго 3/3,
# т.е. статус стоит ровно по центру.
printf '┃ ┃ ┃ ┃ ┃ ┃   \033[92m█\033[94m──\033[92m█\033[94m   ┃ ┃  ┃ ┃ ┃\n'
cat << 'BOXART_BOTTOM'
┃ ┃  ┃ ┃ ┃          ┃ ┃ ┃ ┃ ┃ ┃
┃ ┃ ┃  ┃ ┃          ┃ ┃ ┃ ┃ ┃ ┃
┃ ┃ ┃ ┃ ┃ ┗━━━━━━━━━━┛ ┃ ┃ ┃ ┃ ┃
┃ ┃ ┃ ┃ ┗━━━━━━━━━━━━━━┛ ┃ ┃  ┃
┃ ┃ ┃ ┗━━━━━━━━━━━━━━━━━━┛ ┃ ┃ 
┃ ┃ ┗━━━━━━━━━━━━━━━━━━━━━━┛ ┃ ┃
┃ ┗━━━━━━━━━━━━━━━━━━━━━━━━━━┛ ┃
┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
BOXART_BOTTOM
printf '\033[0m\n'
} > /root/.config/fastfetch/logo.txt
printf "✅  Файл логотипа создан: /root/.config/fastfetch/logo.txt\n"
# --- Рамки секций генерируем программно: раньше линии ─ были набраны "на глаз",
# из-за чего верх/низ секций имели разную длину (правый край "съезжал"),
# а заголовки стояли не по центру. Теперь все рамки одной ширины и центрованы.
SEC_WIDTH=88
repeat_ch() { local n="$1" c="$2" out="" i; for ((i=0;i<n;i++)); do out+="$c"; done; printf '%s' "$out"; }
make_box() { # $1 = заголовок; результат в BOX_T / BOX_B
local inner=$((SEC_WIDTH-2)) pad l r
pad=$((inner - ${#1})); l=$((pad/2)); r=$((pad-l))
BOX_T="┌$(repeat_ch "$l" '─')$1$(repeat_ch "$r" '─')┐"
BOX_B="└$(repeat_ch "$inner" '─')┘"
}
make_box "Hardware";          HW_T="$BOX_T"; HW_B="$BOX_B"
make_box "Software";          SW_T="$BOX_T"; SW_B="$BOX_B"
make_box "Network";           NW_T="$BOX_T"; NW_B="$BOX_B"
make_box "Uptime / Age / DT"; UP_T="$BOX_T"; UP_B="$BOX_B"
# --- Вставляем ваш рабочий конфиг fastfetch (рамки секций подставляются из
# сгенерированных выше переменных через токены @...@) ---
cat > /root/.config/fastfetch/config.jsonc << 'FFCONFIG'
{
"$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",
"logo": {
"type": "file",
"source": "/root/.config/fastfetch/logo.txt",
"padding": { "top": 1, "left": 2, "right": 4 }
},
"display": {
"color": { "keys": "blue", "title": "bright_magenta", "separator": "white" }
},
"modules": [
{ "type": "custom", "format": "\u001b[97m@HW_T@\u001b[0m" },
{ "type": "host", "key": "▣ PC : ", "keyColor": "green" },
{ "type": "cpu", "key": "   ├▢ CPU: ", "keyColor": "green" },
{ "type": "cpuusage", "key": "   ├▢ Usage: ", "keyColor": "green" },
{ "type": "loadavg", "key": "   ├▢ Load: ", "keyColor": "green" },
{ "type": "gpu", "key": "   ├▢ GPU: ", "keyColor": "green" },
{ "type": "memory", "key": "   ├▢ RAM: ", "keyColor": "green" },
{ "type": "swap", "key": "   ├▢ Swap: ", "keyColor": "green" },
{ "type": "disk", "key": "   ├▢ Disk: ", "keyColor": "green" },
{ "type": "battery", "key": "   ├▢ Battery: ", "keyColor": "green" },
{ "type": "poweradapter", "key": "   └ Power: ", "keyColor": "green" },
{ "type": "custom", "format": "\u001b[97m@HW_B@\u001b[0m" },
"break",
{ "type": "custom", "format": "\u001b[97m@SW_T@\u001b[0m" },
{ "type": "os", "key": "▣ OS : ", "keyColor": "yellow" },
{ "type": "kernel", "key": "   ├▢ Kernel: ", "keyColor": "yellow" },
{ "type": "bios", "key": "   ├▢ BIOS: ", "keyColor": "yellow" },
{ "type": "packages", "key": "   ├▢ Packages: ", "keyColor": "yellow" },
{ "type": "shell", "key": "   ├▢ Shell: ", "keyColor": "yellow" },
{ "type": "locale", "key": "   └▢ Locale: ", "keyColor": "yellow" },
{ "type": "custom", "format": "\u001b[97m@SW_B@\u001b[0m" },
"break",
{ "type": "custom", "format": "\u001b[97m@NW_T@\u001b[0m" },
{ "type": "localip", "key": "▣ IP : ", "keyColor": "cyan" },
{
"type": "command",
"key": "   └▢ Location: ",
"keyColor": "cyan",
"text": "city=$(curl -s --max-time 2 https://ipinfo.io/city); country=$(curl -s --max-time 2 https://ipinfo.io/country); if [ -n \"$city\" ] || [ -n \"$country\" ]; then echo \"$city, $country\"; else echo unknown; fi"
},
{ "type": "custom", "format": "\u001b[97m@NW_B@\u001b[0m" },
"break",
{ "type": "custom", "format": "\u001b[97m@UP_T@\u001b[0m" },
{ "type": "uptime", "key": "▣ UP : ", "keyColor": "magenta" },
{
"type": "command",
"key": "   ├⏳ : ",
"keyColor": "magenta",
"text": "birth_install=$(stat -c %W /); current=$(date +%s); time_progression=$((current - birth_install)); days_difference=$((time_progression / 86400)); echo $days_difference days"
},
{ "type": "datetime", "key": "   └⏰ : ", "keyColor": "magenta" },
{ "type": "custom", "format": "\u001b[97m@UP_B@\u001b[0m" },
{ "type": "colors", "paddingLeft": 2, "symbol": "circle" }
]
}
FFCONFIG
# Подставляем сгенерированные рамки вместо токенов
sed -i \
-e "s|@HW_T@|$HW_T|" -e "s|@HW_B@|$HW_B|" \
-e "s|@SW_T@|$SW_T|" -e "s|@SW_B@|$SW_B|" \
-e "s|@NW_T@|$NW_T|" -e "s|@NW_B@|$NW_B|" \
-e "s|@UP_T@|$UP_T|" -e "s|@UP_B@|$UP_B|" \
/root/.config/fastfetch/config.jsonc
printf "✅  Конфиг fastfetch создан: /root/.config/fastfetch/config.jsonc\n"
# --- Отключение стандартного MOTD (как было у вас ранее) ---
printf "• Отключаем стандартный MOTD...\n"
# Отключаем динамический MOTD (Ubuntu/Debian)
if [ -d /etc/update-motd.d ]; then
chmod -x /etc/update-motd.d/* 2>/dev/null || true
printf "  ✓ Скрипты /etc/update-motd.d отключены\n"
fi
# Очищаем статический /etc/motd
truncate -s 0 /etc/motd 2>/dev/null || true
# Отключаем PrintLastLog и PrintMotd в sshd_config
if grep -q "^PrintMotd" "$SSH_CONFIG" 2>/dev/null; then
sed -i 's/^PrintMotd.*/PrintMotd no/' "$SSH_CONFIG"
else
echo "PrintMotd no" >> "$SSH_CONFIG"
fi
if grep -q "^PrintLastLog" "$SSH_CONFIG" 2>/dev/null; then
sed -i 's/^PrintLastLog.*/PrintLastLog no/' "$SSH_CONFIG"
else
echo "PrintLastLog no" >> "$SSH_CONFIG"
fi
# --- Запуск fastfetch при SSH-сессии через /etc/profile.d ---
# Создаём /etc/profile.d/fastfetch-ssh.sh с guard'ом, чтобы fastfetch запускался лишь один раз
cat > /etc/profile.d/fastfetch-ssh.sh << 'PROFEOF'
# fastfetch: run once per session (guarded)
if [ -n "${FASTFETCH_RAN:-}" ]; then
return 0
fi
if [ -n "$SSH_CONNECTION" ] && command -v fastfetch >/dev/null 2>&1; then
fastfetch
export FASTFETCH_RAN=1
fi
PROFEOF
chmod 0644 /etc/profile.d/fastfetch-ssh.sh
printf "✅  /etc/profile.d/fastfetch-ssh.sh создан (fastfetch запускается при SSH, только один раз)\n"
fi
# === Блок 8: Итоговая информация ===
printf "\n✅  Готово! Сервер предварительно настроен.\n"
if [ "$SKIP_SSH_SETUP" = true ]; then
printf "   • SSH настройка: ПРОПУЩЕНА (порт %s занят)\n" "$DEFAULT_PORT"
else
printf "   • Порт SSH: %s\n" "$SSH_PORT"
fi
printf "   • Root-доступ: Разрешен (только по ключу)\n"
printf "   • Вход по паролю: Отключен\n"
printf "   • Fail2ban: Активен\n"
printf "   • Автообновления: Включены (ежедневно в 03:00)\n"
if $FASTFETCH_INSTALLED; then
printf "   • Fastfetch: Установлен (запускается при SSH-входе вместо MOTD)\n"
fi
printf "\n"
printf "⚠️  ВАЖНО: Не закрывайте текущее соединение, пока не проверите вход по новому порту в другом окне!\n"
if [ "$SKIP_SSH_SETUP" = true ]; then
printf "   • SSH конфигурация пропущена — проверьте настройки вручную при необходимости.\n"
else
printf "   • Команда для проверки: ssh -p %s root@<IP_СЕРВЕРА>\n" "$SSH_PORT"
fi
# === Установка метки запуска ===
mkdir -p "$MARKER_DIR"
{
echo "version=$SCRIPT_VERSION"
echo "ran_at=$(date '+%F %T')"
echo "ssh_port=${SSH_PORT:-skipped}"
} > "$MARKER_FILE"
chmod 0644 "$MARKER_FILE"
printf "🏷️   Метка запуска установлена: %s\n" "$MARKER_FILE"
# === Блок 9: Перезагрузка ===
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
