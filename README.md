# preServer.sh

Скрипт первичной настройки безопасности свежего Linux-сервера (Ubuntu/Debian). Разворачивается одной командой сразу после выдачи VPS, приводит систему к безопасному базовому состоянию: обновления, SSH по ключу без пароля, fail2ban, автообновления по расписанию и удобный MOTD-дэшборд при входе.

## Установка

```bash
curl -fsSL https://raw.githubusercontent.com/cryptonoise/sysadmin/refs/heads/main/preServer.sh | sudo bash
```

## Что делает

1. **Восстановление пакетного менеджера** — если обнаружены следы прерванной установки apt/dpkg (зависшие локи, недокомфигурированные пакеты), автоматически чинит их перед началом работы.
2. **Обновление системы** — `apt update && apt upgrade && apt dist-upgrade && apt autoremove` в неинтерактивном режиме (без всплывающих диалогов о конфигах и перезапуске служб).
3. **Установка базовых утилит** — `unattended-upgrades`, `fail2ban`, `htop`, `iotop`, `nethogs`, `curl`, `wget`, `git`, `cron`, `ripgrep`; уже установленные пакеты пропускаются. Включает и запускает `fail2ban` и `cron`.
4. **Настройка SSH:**
   - запрашивает порт (по умолчанию `1119`), проверяет, что он не занят другим сервисом;
   - запрашивает публичный ключ (валидирует формат — rsa/ed25519/ecdsa) и добавляет его в `/root/.ssh/authorized_keys`;
   - в `sshd_config` включает вход по ключу, **отключает вход по паролю**, отключает `UseDNS`;
   - делает бэкап исходного `sshd_config` с таймстампом перед изменением;
   - проверяет корректность конфига (`sshd -t`) перед перезапуском службы — если конфиг битый, скрипт останавливается, не применяя изменения;
   - если порт по умолчанию уже занят — предлагает пропустить настройку SSH целиком, не трогая текущий доступ.
5. **Автообновления по расписанию** — создаёт `/usr/local/sbin/daily-security-update.sh` и задачу в `/etc/cron.d/daily-security-update`, которая ежедневно в 03:00 выполняет `update/upgrade/autoremove` и пишет лог в `/var/log/auto-update.log`.
6. **Fastfetch вместо стандартного MOTD** — устанавливает [Fastfetch](https://github.com/fastfetch-cli/fastfetch) (через PPA, при неудаче — напрямую .deb с GitHub Releases под архитектуру сервера), кладёт готовый конфиг оформления в `/root/.config/fastfetch/config.jsonc`, отключает стандартный Ubuntu/Debian MOTD и `PrintLastLog`, и настраивает автозапуск Fastfetch один раз за SSH-сессию через `/etc/profile.d/fastfetch-ssh.sh`.
7. **Итоговая сводка** — выводит применённые настройки (порт SSH, статус пароля/ключа, fail2ban, расписание автообновлений) и явно предупреждает: проверить вход по новому порту в отдельном окне, прежде чем закрывать текущую сессию.
8. **Метка запуска** — пишет `/var/lib/preserver/.preserver-ran` с версией, временем запуска и выбранным портом SSH (для истории/диагностики, без проверки повторного запуска).
9. **Перезагрузка** — в конце спрашивает, перезагрузить ли сервер сейчас; в неинтерактивном режиме (например, при автоматизации) этот шаг пропускается с подсказкой перезагрузить вручную.

## Требования

- Ubuntu/Debian с `systemd` и `apt`
- root или sudo
- Прямой доступ к `/dev/tty` для интерактивных вопросов (порт SSH, публичный ключ)

## Что изменяется на сервере

| Файл/сервис | Изменение |
|---|---|
| `/etc/ssh/sshd_config` | порт, `PermitRootLogin yes`, `PasswordAuthentication no`, `UseDNS no`, `PrintMotd/PrintLastLog no` (бэкап создаётся автоматически) |
| `/root/.ssh/authorized_keys` | добавляется указанный публичный ключ |
| `/etc/cron.d/daily-security-update` | ежедневное автообновление в 03:00 |
| `/usr/local/sbin/daily-security-update.sh` | скрипт-обёртка автообновления |
| `/etc/profile.d/fastfetch-ssh.sh` | автозапуск Fastfetch при SSH-входе |
| `/etc/update-motd.d/*`, `/etc/motd` | отключаются/очищаются |
| `fail2ban`, `cron` | включаются и запускаются как systemd-сервисы |



server4keymaster
```bash
curl -fsSL https://raw.githubusercontent.com/cryptonoise/sysadmin/refs/heads/main/server4keymaster.sh | bash
```
