#!/bin/bash
set -euo pipefail

# ============================================
# Цветной вывод и логирование
# ============================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
    log_error "Скрипт должен запускаться с правами root (sudo)."
fi

# Определение пакетного менеджера (только apt, т.к. msa.sh заточен под Debian/Ubuntu)
if ! command -v apt &>/dev/null; then
    log_error "Скрипт поддерживает только системы с apt (Debian/Ubuntu)."
fi
PM="apt"

# ============================================
# 1. Автоматические ответы для debconf
# ============================================
log_info "Настройка debconf для автоматических ответов..."
echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
echo "ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula boolean true" | debconf-set-selections

# ============================================
# 2. Обновление системы и установка пакетов
# ============================================
log_info "=== 1. Обновление пакетов ==="
apt-get update -y
apt-get upgrade -y

log_info "=== 2. Установка необходимых пакетов ==="
PACKAGES="mc apache2 samba smbclient cifs-utils iptables-persistent megatools"
DEBIAN_FRONTEND=noninteractive apt-get install -y $PACKAGES

# ============================================
# 3. Настройка Apache и генерация SSL-сертификата
# ============================================
log_info "=== 3. Настройка Apache и генерация SSL-сертификата ==="
systemctl enable apache2
systemctl start apache2

openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /etc/ssl/certs/server.key -out /etc/ssl/certs/server.crt \
    -subj "/C=BY/ST=Minsk/L=BSN/O=IT/CN=server"

chmod 600 /etc/ssl/certs/server.key
chmod 644 /etc/ssl/certs/server.crt
log_info "Сертификат и ключ созданы в /etc/ssl/certs/"

# ============================================
# 4. Настройка Samba
# ============================================
log_info "=== 4. Настройка Samba ==="
cp /etc/samba/smb.conf /etc/samba/smb.conf.bak
log_info "Резервная копия: /etc/samba/smb.conf.bak"

# Изменяем workgroup на BSN
sed -i 's/^[[:space:]]*workgroup[[:space:]]*=[[:space:]]*WORKGROUP/workgroup = BSN/i' /etc/samba/smb.conf

# Добавляем общую папку [obmen]
cat >> /etc/samba/smb.conf << 'EOF'

[obmen]
    comment = Ubuntu File Server Share
    path = /home/obmen
    guest ok = yes
    browsable = yes
    read only = no
    create mask = 0777
    directory mask = 0777
    force create mode = 0777
    force directory mode = 0777
EOF

mkdir -p /home/obmen
chown nobody:nogroup /home/obmen
chmod 777 -R /home/obmen

systemctl restart smbd
log_info "Samba настроена, общая папка /home/obmen"

# ============================================
# 5. Настройка iptables (открытие портов)
# ============================================
log_info "=== 5. Настройка iptables ==="
# Функция добавления правила, если его нет
add_iptable_rule() {
    iptables -C "$@" 2>/dev/null || iptables -A "$@"
}

# Разрешаем уже установленные соединения
add_iptable_rule INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Samba
add_iptable_rule INPUT -p tcp --dport 445 -j ACCEPT
add_iptable_rule INPUT -p tcp --dport 139 -j ACCEPT
add_iptable_rule INPUT -p udp --dport 137:138 -j ACCEPT

# HTTP / HTTPS
add_iptable_rule INPUT -p tcp --dport 80 -j ACCEPT
add_iptable_rule INPUT -p tcp --dport 443 -j ACCEPT

# SSH
add_iptable_rule INPUT -p tcp --dport 22 -j ACCEPT

# PostgreSQL (порт по умолчанию 5432) – пригодится для 1С
add_iptable_rule INPUT -p tcp --dport 5432 -j ACCEPT

log_info "Правила iptables добавлены."

# ============================================
# 6. Сохранение правил iptables
# ============================================
log_info "=== 6. Сохранение правил iptables ==="
netfilter-persistent save
log_info "Правила iptables сохранены."

# ============================================
# 7. Скачивание с Mega.nz и запуск ebash.sh
# ============================================
log_info "=== 7. Скачивание архива с Mega.nz и запуск ebash.sh ==="

MEGA_URL="https://mega.nz/folder/OEpFzYRC#476A2ASra-lgdf4uec4Vrg"
WORK_DIR="./mega_download"

# Проверка наличия megadl (уже установлен)
if ! command -v megadl &> /dev/null; then
    log_error "megadl не найден, хотя пакет megatools должен быть установлен."
fi

# Создаём рабочую папку и переходим в неё
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

log_info "Скачивание папки с Mega.nz ..."
megadl "$MEGA_URL"

# Поиск ebash.sh в скачанных файлах
EBASH_SCRIPT=$(find . -type f -name "ebash.sh" | head -1)

if [[ -z "$EBASH_SCRIPT" ]]; then
    log_error "Файл ebash.sh не найден в скачанной папке."
fi

log_info "Найден ebash.sh: $EBASH_SCRIPT"

# Переходим в папку скрипта
EBASH_DIR=$(dirname "$EBASH_SCRIPT")
cd "$EBASH_DIR"
log_info "Перешли в: $(pwd)"

# Даём права на выполнение всем файлам в этой папке (рекурсивно)
log_info "Устанавливаем права на выполнение для всех файлов..."
find . -type f -exec chmod +x {} \;

# Запускаем ebash.sh
chmod +x ebash.sh
log_info "Запускаем ebash.sh ..."
./ebash.sh
# После завершения ebash.sh продолжаем выполнение

log_info "ebash.sh завершил работу."

# ============================================
# 8. Перезагрузка системы
# ============================================
log_info "=== 8. Перезагрузка системы через 5 секунд ==="
sleep 5
reboot
