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

# Определение пакетного менеджера
if command -v apt &>/dev/null; then
    PM="apt"
elif command -v dnf &>/dev/null; then
    PM="dnf"
elif command -v yum &>/dev/null; then
    PM="yum"
else
    log_error "Не удалось определить пакетный менеджер (поддерживаются apt, dnf, yum)."
fi

# Общие переменные
ARCH=$(uname -m)
SDIR=$(dirname "$(readlink -f "$0")")
SRC_DIR="$SDIR/src"
SBIN_DIR="$SDIR/sbin"

# Поиск установщика 1С
if [[ -n "${ONEC_INSTALLER:-}" ]] && [[ -f "$ONEC_INSTALLER" ]]; then
    INSTALLER_RUN="$ONEC_INSTALLER"
else
    mapfile -t RUN_FILES < <(find "$SDIR" -maxdepth 1 -name "setup-full-*.run" -type f 2>/dev/null)
    if [[ ${#RUN_FILES[@]} -eq 1 ]]; then
        INSTALLER_RUN="${RUN_FILES[0]}"
    else
        log_error "Не найден ровно один файл установщика 1С (setup-full-*.run) в $SDIR. Найдено: ${#RUN_FILES[@]}. Укажите переменную ONEC_INSTALLER."
    fi
fi
INSTALLER_RUN=$(echo "$INSTALLER_RUN" | xargs)
ONEC_VERSION=$(basename "$INSTALLER_RUN" | grep -oP '[\d\.]+' | head -1)
ONEC_DIR="/opt/1cv8/x86_64/${ONEC_VERSION}"
SERVICE_NAME="srv1cv8-${ONEC_VERSION}@default"
RAS_SERVICE_SRC="${ONEC_DIR}/ras-${ONEC_VERSION}.service"
RAS_SERVICE_DST="${ONEC_DIR}/ras.service"

log_info "Найден установщик: $INSTALLER_RUN (версия $ONEC_VERSION)"

# Функция установки пакетов
install_packages() {
    log_info "Установка пакетов: $*"
    case $PM in
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get update -y
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
            ;;
        dnf|yum)
            $PM install -y epel-release 2>/dev/null || true
            $PM makecache
            $PM install -y "$@"
            ;;
    esac
}

# ============================================
# 1. ОБНОВЛЕНИЕ СИСТЕМЫ И УСТАНОВКА БАЗОВЫХ ПАКЕТОВ
# ============================================
log_info "=== 1. Обновление системы и установка базовых пакетов ==="
case $PM in
    apt)
        apt-get update -y
        apt-get upgrade -y
        ;;
    dnf|yum)
        $PM update -y
        ;;
esac

# Устанавливаем общие пакеты (из msa) и зависимости для HASP, шрифтов и т.д.
BASE_PKGS="mc apache2 samba smbclient cifs-utils"
HASP_PKGS=""
FONTS_PKGS=""
IPTABLES_PKGS=""
case $PM in
    apt)
        BASE_PKGS="$BASE_PKGS iptables-persistent"
        HASP_PKGS="dkms g++ libjansson-dev"
        FONTS_PKGS="ttf-mscorefonts-installer fontconfig"
        IPTABLES_PKGS=""
        # Автоматические ответы для iptables-persistent
        echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
        echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
        # Автоматический ответ для ttf-mscorefonts-installer
        echo "ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula boolean true" | debconf-set-selections
        ;;
    dnf|yum)
        HASP_PKGS="dkms gcc-c++ jansson-devel"
        FONTS_PKGS="curl cabextract xorg-x11-font-utils fontconfig"
        IPTABLES_PKGS="iptables-services"
        ;;
esac
install_packages $BASE_PKGS $HASP_PKGS $FONTS_PKGS $IPTABLES_PKGS

# Для dnf/yum дополнительно установим msttcorefonts из rpm
if [[ "$PM" == "dnf" || "$PM" == "yum" ]]; then
    rpm -Uvh https://downloads.sourceforge.net/project/mscorefonts2/rpms/msttcore-fonts-installer-2.6-1.noarch.rpm 2>/dev/null || log_warn "Не удалось установить msttcorefonts"
fi

# ============================================
# 2. НАСТРОЙКА APACHE И ГЕНЕРАЦИЯ SSL-СЕРТИФИКАТА
# ============================================
log_info "=== 2. Настройка Apache и генерация SSL-сертификата ==="
systemctl enable apache2 || log_warn "Не удалось включить apache2"
systemctl start apache2 || log_warn "Не удалось запустить apache2"

# Генерация самоподписанного сертификата (действителен 365 дней)
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /etc/ssl/certs/server.key -out /etc/ssl/certs/server.crt \
    -subj "/C=BY/ST=Minsk/L=BSN/O=IT/CN=server"

chmod 600 /etc/ssl/certs/server.key
chmod 644 /etc/ssl/certs/server.crt
log_info "Сертификат и ключ созданы в /etc/ssl/certs/"

# ============================================
# 3. НАСТРОЙКА SAMBA (ОБЩАЯ ПАПКА)
# ============================================
log_info "=== 3. Настройка Samba ==="
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

# Создаём общую папку и выставляем права
mkdir -p /home/obmen
chown nobody:nogroup /home/obmen
chmod 777 -R /home/obmen

systemctl restart smbd || log_warn "Не удалось перезапустить smbd"

# ============================================
# 4. НАСТРОЙКА IPTABLES (ОТКРЫТИЕ ПОРТОВ)
# ============================================
log_info "=== 4. Настройка iptables для Samba, HTTP, HTTPS, PostgreSQL, SSH ==="
# Функция добавления правила, если его нет
add_iptable_rule() {
    iptables -C "$@" 2>/dev/null || iptables -A "$@"
}

# Разрешаем уже установленные соединения (рекомендуется)
add_iptable_rule INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Samba
add_iptable_rule INPUT -p tcp --dport 445 -j ACCEPT
add_iptable_rule INPUT -p tcp --dport 139 -j ACCEPT
add_iptable_rule INPUT -p udp --dport 137:138 -j ACCEPT

# HTTP и HTTPS
add_iptable_rule INPUT -p tcp --dport 80 -j ACCEPT
add_iptable_rule INPUT -p tcp --dport 443 -j ACCEPT

# PostgreSQL (по умолчанию 5432)
add_iptable_rule INPUT -p tcp --dport 5432 -j ACCEPT

# SSH (на всякий случай, если вдруг закрыт)
add_iptable_rule INPUT -p tcp --dport 22 -j ACCEPT

# Сохранение правил
log_info "Сохранение правил iptables..."
case $PM in
    apt)
        netfilter-persistent save
        ;;
    dnf|yum)
        service iptables save || iptables-save > /etc/sysconfig/iptables
        systemctl restart iptables || true
        ;;
esac

# ============================================
# 5. УСТАНОВКА HASP (ДРАЙВЕРЫ, СЕРВИСЫ)
# ============================================
log_info "=== 5. Установка драйверов и сервисов HASP ==="

if [[ ! -d "$SRC_DIR" ]]; then
    log_error "Папка src/ не найдена в текущей директории."
fi
if [[ ! -d "$SBIN_DIR" ]]; then
    log_error "Папка sbin/ не найдена в текущей директории."
fi

# Установка зависимостей для сборки HASP уже выполнена на шаге 1

# 5.1 usb-vhci-hcd
log_info "Компиляция usb-vhci-hcd..."
VHCI_DIR="$SRC_DIR/usb-vhci-hcd-1.15.1"
if [[ ! -d "$VHCI_DIR" ]]; then
    log_error "Папка $VHCI_DIR не найдена."
fi

cp -fpr "$VHCI_DIR" /usr/src/
cp -f "/usr/src/usb-vhci-hcd-1.15.1/usb-vhci.h" /usr/include/linux/

if dkms status 2>/dev/null | grep -q "usb-vhci-hcd/1.15.1"; then
    log_info "Модуль usb-vhci-hcd/1.15.1 уже присутствует в DKMS. Удаляем..."
    dkms remove -m usb-vhci-hcd -v 1.15.1 --all || true
    modprobe -r usb_vhci_hcd 2>/dev/null || true
    modprobe -r usb_vhci_iocifc 2>/dev/null || true
fi

dkms add -m usb-vhci-hcd -v 1.15.1
dkms build -m usb-vhci-hcd -v 1.15.1
dkms install -m usb-vhci-hcd -v 1.15.1
modprobe usb_vhci_hcd || log_warn "Не удалось загрузить модуль usb_vhci_hcd"
modprobe usb_vhci_iocifc || log_warn "Не удалось загрузить модуль usb_vhci_iocifc"

# 5.2 libusb_vhci
log_info "Компиляция libusb_vhci..."
cd "$SRC_DIR/libusb_vhci-0.8/"
./configure CXXFLAGS='-std=c++11' --prefix=/usr
make
make install
ldconfig

# 5.3 usbhasp
log_info "Компиляция usbhasp..."
cd "$SRC_DIR/UsbHasp/"
make clean
make CFLAGS=-std=gnu99
cp -fp "$SRC_DIR/UsbHasp/dist/Release/GNU-Linux/usbhasp" /usr/bin/

# 5.4 Настройка usbhaspd и копирование ключей
log_info "Настройка usbhaspd..."
mkdir -p /etc/usbhaspd/keys/

if [[ -d "$SDIR/keys" ]] && [[ -n "$(ls -A "$SDIR/keys")" ]]; then
    log_info "Копирование файлов ключей из $SDIR/keys в /etc/usbhaspd/keys/"
    cp -f "$SDIR/keys"/* /etc/usbhaspd/keys/ 2>/dev/null || log_warn "Не удалось скопировать некоторые файлы ключей"
else
    log_info "Папка с ключами ($SDIR/keys) не найдена или пуста. Пропускаем."
fi

cat > /etc/usbhaspd/usbhaspd.conf <<EOF
# Usbhaspd conf
# KEY_DIR=/etc/usbhaspd/keys
EOF

cat > /usr/bin/usbhaspd <<'EOF'
#!/bin/bash
NAME=usbhaspd
DAEMON_BIN=/usr/bin/usbhasp
KEY_DIR=/etc/${NAME}/keys
DAEMON_CONF=/etc/${NAME}/${NAME}.conf
[ -f "$DAEMON_CONF" ] && . "$DAEMON_CONF"
keys=""
[ -d "$KEY_DIR" ] && keys="$KEY_DIR"/*.json
DAEMON_ARGS="$keys"
modprobe usb_vhci_hcd 2>/dev/null || true
modprobe usb_vhci_iocifc 2>/dev/null || true
exec $DAEMON_BIN $DAEMON_ARGS
EOF
chmod a+x /usr/bin/usbhaspd

cat > /lib/systemd/system/usbhaspd.service <<EOF
[Unit]
Description=Usbhasp daemon
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/usbhaspd
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# 5.5 aksusbd / hasplm
log_info "Установка компонентов Sentinel..."
if [[ $ARCH == "x86_64" ]]; then
    aksusbd_bin="aksusbd_x86_64"
else
    aksusbd_bin="aksusbd"
fi

if [[ ! -f "$SBIN_DIR/$aksusbd_bin" ]] || [[ ! -f "$SBIN_DIR/hasplm" ]]; then
    log_error "Бинарные файлы aksusbd или hasplm не найдены в $SBIN_DIR"
fi
cp -fp "$SBIN_DIR/$aksusbd_bin" /usr/sbin/
cp -fp "$SBIN_DIR/hasplm" /usr/sbin/

# 5.6 udev правила
log_info "Настройка udev правил..."
cat > /etc/udev/rules.d/80-hasp.rules <<EOF
ACTION=="add|change|bind", SUBSYSTEM=="usb", ATTRS{idVendor}=="0529", ATTRS{idProduct}=="0001", MODE="664", ENV{HASP}="1", SYMLINK+="aks/hasp/%k", RUN+="/usr/sbin/$aksusbd_bin -c \$root/aks/hasp/\$kernel"
ACTION=="remove", ENV{HASP}=="1", RUN+="/usr/sbin/$aksusbd_bin -r \$root/aks/hasp/\$kernel"
ACTION=="add|change|bind", SUBSYSTEM=="usb", ATTRS{idVendor}=="0529", ATTRS{idProduct}=="0003", KERNEL!="hiddev*", MODE="666", GROUP="plugdev", ENV{SENTINELHID}="1", SYMLINK+="aks/sentinelhid/%k"
EOF

# 5.7 Конфигурация hasplm
mkdir -p /etc/hasplm/
cat > /etc/hasplm/hasplm.conf <<EOF
[NHS_SERVER]
NHS_USERLIST     = 250
NHS_HIGHPRIORITY = no

[NHS_IP]
NHS_USE_UDP      = Enabled
NHS_USE_TCP      = Disabled
NHS_IP_portnum   = 475
EOF

cat > /etc/hasplm/nethasp.ini <<EOF
[NH_COMMON]
NH_TCPIP = Enabled

[NH_TCPIP]
NH_SERVER_ADDR = 127.0.0.1
NH_USE_BROADCAST = Disabled
EOF

# 5.8 systemd сервисы для aksusbd / hasplm
cat > /etc/systemd/system/aksusbd.service <<EOF
[Unit]
Description=Sentinel LDK Runtime Environment (aksusbd)
After=network.target

[Service]
Type=forking
ExecStart=/usr/sbin/$aksusbd_bin
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/hasplm.service <<EOF
[Unit]
Description=Sentinel License Manager
After=network.target aksusbd.service

[Service]
Type=forking
ExecStart=/usr/sbin/hasplm -c /etc/hasplm/hasplm.conf
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# 5.9 Компиляция usbhaspinfo
log_info "Компиляция usbhaspinfo..."
cd "$SRC_DIR/UsbHaspInfo/"
if [[ $ARCH == "x86_64" ]]; then
    case $PM in
        apt) install_packages gcc-multilib ;;
        dnf|yum) install_packages libgcc.i686 glibc-devel.i686 ;;
    esac
    m32="-m32"
else
    m32=""
fi
gcc $m32 -c *.c
gcc $m32 *.o libhasplnx.a -o usbhaspinfo
cp -fp usbhaspinfo /usr/sbin/

# 5.10 Запуск сервисов HASP
log_info "Активация systemd сервисов HASP..."
systemctl daemon-reload
for svc in aksusbd hasplm usbhaspd; do
    systemctl stop $svc 2>/dev/null || true
    systemctl enable $svc
    systemctl start $svc
    systemctl is-active --quiet $svc || log_warn "Сервис $svc не запустился"
done

# ============================================
# 6. УСТАНОВКА ШРИФТОВ
# ============================================
log_info "=== 6. Установка шрифтов ==="
# Уже установлены на шаге 1, но доделаем
fc-cache -fv

# ============================================
# 7. УСТАНОВКА 1С
# ============================================
log_info "=== 7. Установка сервера 1С:Предприятие ==="
if [[ ! -f "$INSTALLER_RUN" ]]; then
    log_error "Файл $INSTALLER_RUN не найден."
fi
chmod +x "$INSTALLER_RUN"
log_info "Запуск: $INSTALLER_RUN --mode unattended --enable-components server,ws"
"$INSTALLER_RUN" --mode unattended --enable-components server,ws
if [[ $? -ne 0 ]]; then
    log_error "Ошибка при выполнении установщика 1С"
fi

# ============================================
# 8. НАСТРОЙКА СЕРВИСА 1С
# ============================================
log_info "=== 8. Настройка systemd-сервиса 1С ==="
systemd_service_file="${ONEC_DIR}/srv1cv8-${ONEC_VERSION}@.service"
if [[ -f "$systemd_service_file" ]]; then
    systemctl link "$systemd_service_file"
    systemctl enable "$SERVICE_NAME"
    systemctl start "$SERVICE_NAME"
    systemctl status "$SERVICE_NAME" --no-pager || log_warn "Сервис 1С не активен"
else
    log_error "Файл сервиса $systemd_service_file не найден."
fi

# ============================================
# 9. НАСТРОЙКА RAS
# ============================================
log_info "=== 9. Настройка RAS ==="
if [[ -f "$RAS_SERVICE_SRC" ]]; then
    mv "$RAS_SERVICE_SRC" "$RAS_SERVICE_DST"
    systemctl link "$RAS_SERVICE_DST"
    systemctl enable ras.service
    systemctl start ras.service
else
    log_warn "Файл $RAS_SERVICE_SRC не найден. RAS не настроен."
fi

# ============================================
# 10. УСТАНОВКА POSTGRES PRO 1C-18
# ============================================
log_info "=== 10. Установка PostgreSQL Pro 1C-18 ==="
wget -q https://repo.postgrespro.ru/1c/1c-18/keys/pgpro-repo-add.sh
bash pgpro-repo-add.sh
rm -f pgpro-repo-add.sh
case $PM in
    apt)
        apt-get update -y
        DEBIAN_FRONTEND=noninteractive apt-get install -y postgrespro-1c-18
        ;;
    dnf|yum)
        $PM install -y postgrespro-1c-18
        ;;
esac

# ============================================
# 11. ИНИЦИАЛИЗАЦИЯ И ЗАПУСК POSTGRESQL
# ============================================
log_info "=== 11. Проверка и инициализация PostgreSQL ==="

PGDATA="/var/lib/pgpro/1c-18/data"
PG_BIN="/opt/pgpro/1c-18/bin"
PG_SERVICE="postgrespro-1c-18"

check_postgres() {
    su - postgres -c "psql -c 'SELECT version();'" &>/dev/null
}

if check_postgres; then
    log_info "PostgreSQL уже работает."
else
    log_warn "PostgreSQL не отвечает. Выполняем инициализацию и запуск..."
    if [[ ! -d "$PGDATA" ]] || [[ -z "$(ls -A "$PGDATA" 2>/dev/null)" ]]; then
        su - postgres -c "$PG_BIN/initdb -D $PGDATA" || log_error "Ошибка инициализации PostgreSQL"
    fi
    if command -v systemctl &>/dev/null; then
        systemctl start "$PG_SERVICE" || su - postgres -c "$PG_BIN/pg_ctl start -D $PGDATA"
    else
        su - postgres -c "$PG_BIN/pg_ctl start -D $PGDATA"
    fi
    sleep 5
    if ! check_postgres; then
        log_error "Не удалось запустить PostgreSQL."
    fi
    log_info "PostgreSQL успешно инициализирован и запущен."
fi

# ============================================
# 12. ДОНАСТРОЙКА POSTGRESQL ДЛЯ 1С
# ============================================
log_info "=== 12. Донастройка PostgreSQL Pro 1C-18 ==="

if [[ ! -f "$PGDATA/postgresql.conf" ]]; then
    log_error "Файл $PGDATA/postgresql.conf не найден."
fi
if [[ ! -f "$PGDATA/pg_hba.conf" ]]; then
    log_error "Файл $PGDATA/pg_hba.conf не найден."
fi

# Разрешаем удалённые подключения
log_info "Настройка postgresql.conf: listen_addresses = '*'"
if grep -q "^listen_addresses" "$PGDATA/postgresql.conf"; then
    sed -i "s/^#\{0,1\}listen_addresses = .*/listen_addresses = '*'/" "$PGDATA/postgresql.conf"
else
    echo "listen_addresses = '*'" >> "$PGDATA/postgresql.conf"
fi

# Добавляем правило для сети 192.168.0.0/16
log_info "Настройка pg_hba.conf: добавление правила для подсети 192.168.0.0/16"
if ! grep -q "192.168.0.0/16" "$PGDATA/pg_hba.conf"; then
    if grep -q "^# IPv4 local connections:" "$PGDATA/pg_hba.conf"; then
        sed -i '/^# IPv4 local connections:/a host    all             all             192.168.0.0/16          md5' "$PGDATA/pg_hba.conf"
    else
        echo "host    all             all             192.168.0.0/16          md5" >> "$PGDATA/pg_hba.conf"
    fi
else
    log_info "Правило уже присутствует в pg_hba.conf"
fi

# Обновление pg-wrapper (если установлен)
log_info "Обновление ссылок pg-wrapper..."
if command -v pg-wrapper &>/dev/null; then
    pg-wrapper links update || log_warn "Ошибка при обновлении pg-wrapper, но это не критично"
else
    log_info "pg-wrapper не найден, пропускаем"
fi

# Перезапуск PostgreSQL
log_info "Перезапуск PostgreSQL..."
if command -v systemctl &>/dev/null; then
    systemctl restart "$PG_SERVICE" || log_error "Не удалось перезапустить $PG_SERVICE через systemctl"
else
    su - postgres -c "$PG_BIN/pg_ctl restart -D $PGDATA" || log_error "Не удалось перезапустить PostgreSQL"
fi
sleep 3

if check_postgres; then
    log_info "PostgreSQL успешно перезапущен и работает"
else
    log_error "PostgreSQL не отвечает после перезапуска"
fi

# ============================================
# 13. УСТАНОВКА ПАРОЛЯ ПОЛЬЗОВАТЕЛЯ postgres
# ============================================
log_info "=== 13. Установка пароля для postgres: Asdf1234 ==="
PG_PASS="Asdf1234"
sudo -u postgres psql <<EOF
ALTER USER postgres PASSWORD '$PG_PASS';
\q
EOF

if [[ $? -eq 0 ]]; then
    log_info "Пароль для postgres успешно изменён на заданный."
else
    log_error "Ошибка при смене пароля."
fi

# ============================================
# 14. ПЕРЕНОС ПАПКИ base В /home/dbpgs (АВТОМАТИЧЕСКИ)
# ============================================
log_info "=== 14. Перенос каталога base в /home/dbpgs ==="
NEW_BASE_DIR="/home/dbpgs"

# Автоматически отвечаем "y"
REPLY="y"
if [[ $REPLY =~ ^[Yy]$ ]]; then
    log_info "Останавливаем PostgreSQL..."
    if command -v systemctl &>/dev/null; then
        systemctl stop "$PG_SERVICE"
    else
        su - postgres -c "$PG_BIN/pg_ctl stop -D $PGDATA"
    fi

    log_info "Создание каталога $NEW_BASE_DIR и установка прав..."
    mkdir -p "$NEW_BASE_DIR"
    chmod 777 -R "$NEW_BASE_DIR"

    log_info "Копирование данных (rsync)..."
    rsync -avx "$PGDATA/base/" "$NEW_BASE_DIR/base/"

    log_info "Переименование старой папки base в base.bak..."
    mv "$PGDATA/base" "$PGDATA/base.bak"

    log_info "Создание символьной ссылки..."
    ln -s "$NEW_BASE_DIR/base" "$PGDATA/base"

    log_info "Удаление резервной копии (base.bak)..."
    rm -Rf "$PGDATA/base.bak"

    log_info "Запуск PostgreSQL..."
    if command -v systemctl &>/dev/null; then
        systemctl start "$PG_SERVICE"
    else
        su - postgres -c "$PG_BIN/pg_ctl start -D $PGDATA"
    fi
    sleep 3
    if check_postgres; then
        log_info "Перенос базы успешно завершён"
    else
        log_error "Ошибка после переноса базы"
    fi
else
    log_info "Перенос базы пропущен."
fi

# ============================================
# 15. ПЕРЕЗАГРУЗКА СИСТЕМЫ
# ============================================
log_info "=== 15. Перезагрузка системы через 5 секунд ==="
sleep 5
reboot