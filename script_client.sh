#!/bin/bash
# Скрипт установки Zabbix Agent 2 на Linux клиенты
# Версия: 2.0

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Функция определения дистрибутива
detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$NAME
        VER=$VERSION_ID
    elif type lsb_release >/dev/null 2>&1; then
        OS=$(lsb_release -si)
        VER=$(lsb_release -sr)
    else
        OS=$(uname -s)
        VER=$(uname -r)
    fi
}

# Функция установки для Ubuntu/Debian
install_debian() {
    log "Установка для Debian/Ubuntu..."
    
    # Добавление репозитория Zabbix
    wget https://repo.zabbix.com/zabbix/6.4/ubuntu/pool/main/z/zabbix-release/zabbix-release_6.4-1+ubuntu$(lsb_release -rs)_all.deb
    dpkg -i zabbix-release_6.4-1+ubuntu$(lsb_release -rs)_all.deb
    apt update
    
    # Установка Zabbix Agent 2
    apt install -y zabbix-agent2 zabbix-agent2-plugin-*
    
    # Включение дополнительных плагинов
    apt install -y zabbix-agent2-plugin-mongodb \
                   zabbix-agent2-plugin-mysql \
                   zabbix-agent2-plugin-postgresql \
                   zabbix-agent2-plugin-docker \
                   zabbix-agent2-plugin-redis
}

# Функция установки для CentOS/RHEL
install_centos() {
    log "Установка для CentOS/RHEL..."
    
    # Добавление репозитория Zabbix
    rpm -Uvh https://repo.zabbix.com/zabbix/6.4/rhel/${VER}/x86_64/zabbix-release-6.4-1.el${VER}.noarch.rpm
    yum clean all
    yum makecache
    
    # Установка Zabbix Agent 2
    yum install -y zabbix-agent2 zabbix-agent2-plugin-*
    
    # Включение дополнительных плагинов
    yum install -y zabbix-agent2-plugin-mongodb \
                   zabbix-agent2-plugin-mysql \
                   zabbix-agent2-plugin-postgresql \
                   zabbix-agent2-plugin-docker \
                   zabbix-agent2-plugin-redis
}

# Функция логирования
log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a /var/log/zabbix-agent-install.log
}

# Основной скрипт
clear
echo -e "${GREEN}==============================================${NC}"
echo -e "${GREEN}   Установка Zabbix Agent 2 на клиенте       ${NC}"
echo -e "${GREEN}==============================================${NC}"
echo ""

# Проверка прав
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Запустите скрипт с правами root (sudo)${NC}"
    exit 1
fi

# Определение дистрибутива
detect_distro
echo -e "${YELLOW}Обнаружена система: $OS $VER${NC}"

# Ввод параметров
read -p "Введите IP адрес Zabbix сервера: " ZABBIX_SERVER
read -p "Введите имя хоста для этого клиента: " HOSTNAME
read -p "Введите метаданные хоста (например: linux,web,prod): " HOST_METADATA

# Установка
log "Начало установки Zabbix Agent 2..."

case $OS in
    *Ubuntu*|*Debian*)
        install_debian
        ;;
    *CentOS*|*Red*Hat*|*Fedora*|*Rocky*|*AlmaLinux*)
        install_centos
        ;;
    *)
        echo -e "${RED}Неподдерживаемый дистрибутив: $OS${NC}"
        exit 1
        ;;
esac

# Настройка конфигурации
log "Настройка конфигурации агента..."

cat > /etc/zabbix/zabbix_agent2.conf << EOF
# Основные настройки
PidFile=/var/run/zabbix/zabbix_agent2.pid
LogFile=/var/log/zabbix/zabbix_agent2.log
LogFileSize=50
DebugLevel=3

# Настройки сервера
Server=$ZABBIX_SERVER
ServerActive=$ZABBIX_SERVER
Hostname=$HOSTNAME
HostMetadata=$HOST_METADATA

# Безопасность
TLSConnect=psk
TLSAccept=psk
TLSPSKIdentity=PSK_$HOSTNAME
TLSPSKFile=/etc/zabbix/zabbix_agent2.psk

# Пользовательские параметры
Include=/etc/zabbix/zabbix_agent2.d/*.conf
UserParameter=custom.*,/etc/zabbix/scripts/\$1

# Настройки плагинов
Plugins.Docker.Endpoint=unix:///var/run/docker.sock
Plugins.Mysql.Socket=/var/run/mysqld/mysqld.sock
Plugins.Postgresql.Url=postgresql://zabbix:zabbix@localhost/zabbix

# Настройки производительности
Timeout=30
BufferSize=100
StartAgents=10
EOF

# Создание PSK ключа для шифрования
log "Генерация PSK ключа..."
openssl rand -hex 32 > /etc/zabbix/zabbix_agent2.psk
chown zabbix:zabbix /etc/zabbix/zabbix_agent2.psk
chmod 600 /etc/zabbix/zabbix_agent2.psk

# Создание каталога для пользовательских скриптов
mkdir -p /etc/zabbix/scripts
chown -R zabbix:zabbix /etc/zabbix/scripts

# Создание стандартных скриптов мониторинга
log "Создание пользовательских скриптов..."

# Мониторинг использования диска
cat > /etc/zabbix/scripts/disk_usage.sh << 'EOF'
#!/bin/bash
# Мониторинг использования диска
df -h / | awk 'NR==2 {print $5}' | sed 's/%//'
EOF

# Мониторинг использования памяти
cat > /etc/zabbix/scripts/memory_usage.sh << 'EOF'
#!/bin/bash
# Мониторинг использования памяти
free | awk '/Mem:/ {printf "%.2f", $3/$2 * 100}'
EOF

# Мониторинг нагрузки системы
cat > /etc/zabbix/scripts/load_average.sh << 'EOF'
#!/bin/bash
# Мониторинг средней нагрузки
case $1 in
    1) uptime | awk '{print $10}' | tr -d ',' ;;
    5) uptime | awk '{print $11}' | tr -d ',' ;;
    15) uptime | awk '{print $12}' | tr -d ',' ;;
    *) echo "0" ;;
esac
EOF

# Мониторинг служб
cat > /etc/zabbix/scripts/service_status.sh << 'EOF'
#!/bin/bash
# Проверка статуса службы
SERVICE=$1
if systemctl is-active --quiet $SERVICE; then
    echo "1"
else
    echo "0"
fi
EOF

# Мониторинг обновлений (для Ubuntu/Debian)
cat > /etc/zabbix/scripts/updates_check.sh << 'EOF'
#!/bin/bash
# Проверка доступных обновлений
if command -v apt-get &> /dev/null; then
    apt-get update > /dev/null 2>&1
    apt-get -s upgrade | grep -c "^Inst"
elif command -v yum &> /dev/null; then
    yum check-update --quiet | grep -vc "^$"
else
    echo "0"
fi
EOF

chmod +x /etc/zabbix/scripts/*.sh

# Создание пользовательских параметров
cat > /etc/zabbix/zabbix_agent2.d/userparams.conf << EOF
# Пользовательские параметры
UserParameter=custom.disk.usage,/etc/zabbix/scripts/disk_usage.sh
UserParameter=custom.memory.usage,/etc/zabbix/scripts/memory_usage.sh
UserParameter=custom.load.average[*],/etc/zabbix/scripts/load_average.sh \$1
UserParameter=custom.service.status[*],/etc/zabbix/scripts/service_status.sh \$1
UserParameter=custom.updates.count,/etc/zabbix/scripts/updates_check.sh

# Мониторинг процессов
UserParameter=proc.num[*],ps aux | grep -c "\$1"

# Мониторинг TCP соединений
UserParameter=tcp.status[*],netstat -an | grep -c "\$1"

# Мониторинг логов
UserParameter=log.check[*],tail -100 "\$1" | grep -c "\$2"
EOF

# Настройка брандмауэра
log "Настройка брандмауэра..."
if command -v ufw &> /dev/null; then
    ufw allow from $ZABBIX_SERVER to any port 10050 proto tcp
    ufw reload
elif command -v firewall-cmd &> /dev/null; then
    firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='$ZABBIX_SERVER' port port='10050' protocol='tcp' accept"
    firewall-cmd --reload
fi

# Запуск и настройка автоматического запуска
log "Запуск Zabbix Agent 2..."
systemctl enable zabbix-agent2
systemctl restart zabbix-agent2

# Проверка статуса
if systemctl is-active --quiet zabbix-agent2; then
    log "Zabbix Agent 2 успешно запущен"
else
    log "Ошибка запуска Zabbix Agent 2"
    systemctl status zabbix-agent2
fi

# Создание информационного файла
cat > /root/zabbix-agent-info.txt << EOF
===============================================
     ZABBIX AGENT 2 УСТАНОВЛЕН
===============================================

Хост: $HOSTNAME
Zabbix Server: $ZABBIX_SERVER
Метаданные: $HOST_METADATA

PSK Identity: PSK_$HOSTNAME
PSK Key: $(cat /etc/zabbix/zabbix_agent2.psk)

Каталоги:
Конфигурация: /etc/zabbix
Скрипты: /etc/zabbix/scripts
Логи: /var/log/zabbix

Команды управления:
systemctl status zabbix-agent2
systemctl restart zabbix-agent2
tail -f /var/log/zabbix/zabbix_agent2.log

Пользовательские скрипты:
Диск: custom.disk.usage
Память: custom.memory.usage
Нагрузка: custom.load.average[1], [5], [15]
Службы: custom.service.status[имя_службы]
Обновления: custom.updates.count

===============================================
Для добавления на сервер используйте PSK ключ:
$(cat /etc/zabbix/zabbix_agent2.psk)
===============================================
EOF

# Вывод информации
echo ""
echo -e "${GREEN}Установка Zabbix Agent 2 завершена!${NC}"
echo ""
echo -e "${YELLOW}Информация:${NC}"
echo -e "Имя хоста: ${GREEN}$HOSTNAME${NC}"
echo -e "Zabbix Server: ${GREEN}$ZABBIX_SERVER${NC}"
echo -e "PSK Identity: ${GREEN}PSK_$HOSTNAME${NC}"
echo -e "PSK Key: ${GREEN}$(cat /etc/zabbix/zabbix_agent2.psk)${NC}"
echo ""
echo -e "${YELLOW}Статус службы:${NC}"
systemctl status zabbix-agent2 --no-pager | head -10
echo ""
echo -e "${YELLOW}Информация сохранена в: /root/zabbix-agent-info.txt${NC}"
