#!/bin/bash
# Скрипт автоматической установки и настройки Zabbix Server 6.4 LTS
# Версия: 1.0
# Автор: System Administrator

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Функция логирования
log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a /var/log/zabbix-install.log
}

# Функция проверки ошибок
check_error() {
    if [ $? -ne 0 ]; then
        echo -e "${RED}Ошибка: $1${NC}" | tee -a /var/log/zabbix-install.log
        exit 1
    fi
}

# Функция вывода заголовка
print_header() {
    clear
    echo -e "${GREEN}==============================================${NC}"
    echo -e "${GREEN}    Установка Zabbix Server 6.4 LTS          ${NC}"
    echo -e "${GREEN}==============================================${NC}"
    echo ""
}

# Проверка прав администратора
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Пожалуйста, запустите скрипт с правами root (sudo)${NC}"
    exit 1
fi

print_header

# Конфигурация установки
ZABBIX_VERSION="6.4"
DB_TYPE="mysql" # или "pgsql" для PostgreSQL
DB_PASSWORD=$(openssl rand -base64 32)
ZABBIX_ADMIN_PASSWORD=$(openssl rand -base64 16)
SERVER_IP=$(hostname -I | awk '{print $1}')
TIMEZONE="Europe/Moscow"

# Вопросы для настройки
read -p "Введите доменное имя или IP сервера [$SERVER_IP]: " SERVER_NAME
SERVER_NAME=${SERVER_NAME:-$SERVER_IP}

read -p "Введите пароль для базы данных Zabbix [автогенерация]: " CUSTOM_DB_PASS
DB_PASSWORD=${CUSTOM_DB_PASS:-$DB_PASSWORD}

read -p "Введите пароль для пользователя Admin Zabbix [автогенерация]: " CUSTOM_ADMIN_PASS
ZABBIX_ADMIN_PASSWORD=${CUSTOM_ADMIN_PASS:-$ZABBIX_ADMIN_PASSWORD}

echo ""
echo -e "${YELLOW}Настройки установки:${NC}"
echo "Версия Zabbix: $ZABBIX_VERSION"
echo "Тип БД: $DB_TYPE"
echo "IP сервера: $SERVER_IP"
echo "Имя сервера: $SERVER_NAME"
echo ""
read -p "Продолжить установку? (y/n): " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 0
fi

# Начало установки
log "Начало установки Zabbix Server"

# Обновление системы
log "Обновление пакетов системы..."
apt update && apt upgrade -y
check_error "Не удалось обновить систему"

# Установка зависимостей
log "Установка необходимых пакетов..."
apt install -y wget curl gnupg2 software-properties-common \
    apache2 php php-mysql php-gd php-xml php-bcmath php-mbstring php-ldap \
    snmp snmpd libsnmp-dev libcurl4-openssl-dev libssl-dev \
    libxml2-dev libssh2-1-dev libopenipmi-dev libpcre3-dev \
    git build-essential ntpdate nginx
check_error "Не удалось установить зависимости"

# Установка и настройка MySQL
if [ "$DB_TYPE" = "mysql" ]; then
    log "Установка MySQL..."
    apt install -y mysql-server mysql-client
    check_error "Не удалось установить MySQL"
    
    # Настройка MySQL
    log "Настройка MySQL..."
    mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$DB_PASSWORD';"
    mysql -e "FLUSH PRIVILEGES;"
    
    # Создание базы данных для Zabbix
    log "Создание базы данных Zabbix..."
    mysql -uroot -p$DB_PASSWORD -e "CREATE DATABASE zabbix CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;"
    mysql -uroot -p$DB_PASSWORD -e "CREATE USER 'zabbix'@'localhost' IDENTIFIED BY '$DB_PASSWORD';"
    mysql -uroot -p$DB_PASSWORD -e "GRANT ALL PRIVILEGES ON zabbix.* TO 'zabbix'@'localhost';"
    mysql -uroot -p$DB_PASSWORD -e "FLUSH PRIVILEGES;"
    
    # Настройка my.cnf
    cat >> /etc/mysql/mysql.conf.d/mysqld.cnf << EOF

[mysqld]
innodb_file_per_table=1
innodb_buffer_pool_size=512M
max_connections=500
max_allowed_packet=16M
character-set-server=utf8mb4
collation-server=utf8mb4_bin
EOF
    
    systemctl restart mysql
    systemctl enable mysql
fi

# Добавление репозитория Zabbix
log "Добавление репозитория Zabbix..."
wget https://repo.zabbix.com/zabbix/$ZABBIX_VERSION/ubuntu/pool/main/z/zabbix-release/zabbix-release_${ZABBIX_VERSION}-1+ubuntu22.04_all.deb
dpkg -i zabbix-release_${ZABBIX_VERSION}-1+ubuntu22.04_all.deb
apt update
rm -f zabbix-release_${ZABBIX_VERSION}-1+ubuntu22.04_all.deb

# Установка Zabbix Server
log "Установка Zabbix Server, Frontend и Agent..."
apt install -y zabbix-server-$DB_TYPE zabbix-frontend-php zabbix-apache-conf \
    zabbix-sql-scripts zabbix-agent zabbix-get zabbix-sender
check_error "Не удалось установить пакеты Zabbix"

# Импорт начальной схемы базы данных
log "Импорт схемы базы данных..."
if [ "$DB_TYPE" = "mysql" ]; then
    zcat /usr/share/zabbix-sql-scripts/mysql/server.sql.gz | mysql -uzabbix -p$DB_PASSWORD zabbix
fi

# Настройка конфигурации Zabbix Server
log "Настройка конфигурации Zabbix Server..."
cat > /etc/zabbix/zabbix_server.conf << EOF
# Конфигурация Zabbix Server
LogFile=/var/log/zabbix/zabbix_server.log
LogFileSize=50
DebugLevel=3
PidFile=/var/run/zabbix/zabbix_server.pid
SocketDir=/var/run/zabbix

DBHost=localhost
DBName=zabbix
DBUser=zabbix
DBPassword=$DB_PASSWORD
DBPort=3306

SNMPTrapperFile=/var/log/snmp/snmptrap.log
Timeout=4
AlertScriptsPath=/usr/lib/zabbix/alertscripts
ExternalScripts=/usr/lib/zabbix/externalscripts
LogSlowQueries=3000

StatsAllowedIP=127.0.0.1
StartPollers=50
StartPollersUnreachable=10
StartTrappers=20
StartPingers=20
StartDiscoverers=15
StartPreprocessors=30
StartHTTPPollers=5
StartAlerters=10
StartTimers=10
StartEscalators=10

CacheSize=512M
HistoryCacheSize=256M
HistoryIndexCacheSize=128M
TrendCacheSize=128M
ValueCacheSize=256M

EOF

# Настройка PHP для Zabbix Frontend
log "Настройка PHP..."
cat > /etc/php/8.1/apache2/conf.d/99-zabbix.ini << EOF
max_execution_time = 300
memory_limit = 256M
post_max_size = 32M
upload_max_filesize = 16M
max_input_time = 300
date.timezone = $TIMEZONE
EOF

# Настройка Apache/Nginx
log "Настройка веб-сервера..."
# Для Apache:
cat > /etc/apache2/sites-available/zabbix.conf << EOF
<VirtualHost *:80>
    ServerName $SERVER_NAME
    DocumentRoot /usr/share/zabbix
    
    <Directory /usr/share/zabbix>
        Options FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>
    
    ErrorLog \${APACHE_LOG_DIR}/zabbix_error.log
    CustomLog \${APACHE_LOG_DIR}/zabbix_access.log combined
</VirtualHost>
EOF

a2ensite zabbix.conf
a2dissite 000-default.conf
a2enmod ssl rewrite headers
systemctl restart apache2

# Альтернативно для Nginx:
# systemctl stop apache2
# apt install -y nginx
# Настройка Nginx для Zabbix...

# Настройка и запуск служб
log "Настройка служб Zabbix..."
systemctl enable zabbix-server zabbix-agent apache2
systemctl restart zabbix-server zabbix-agent apache2

# Настройка брандмауэра
log "Настройка брандмауэра..."
if command -v ufw &> /dev/null; then
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow 10051/tcp
    ufw allow 10050/tcp
    ufw reload
fi

# Настройка периодических задач
log "Настройка периодических задач..."
cat > /etc/cron.d/zabbix-housekeeping << EOF
0 0 * * * zabbix /usr/bin/zabbix_server --runtime-control housekeeper_execute
EOF

# Создание скрипта для мониторинга
log "Создание пользовательских скриптов мониторинга..."
mkdir -p /usr/lib/zabbix/externalscripts
mkdir -p /usr/lib/zabbix/alertscripts

# Пример скрипта для мониторинга
cat > /usr/lib/zabbix/externalscripts/check_service.sh << 'EOF'
#!/bin/bash
# Скрипт проверки службы
SERVICE=$1
if systemctl is-active --quiet $SERVICE; then
    echo "1" # Сервис работает
else
    echo "0" # Сервис не работает
fi
EOF

chmod +x /usr/lib/zabbix/externalscripts/check_service.sh
chown -R zabbix:zabbix /usr/lib/zabbix/externalscripts/

# Создание скрипта оповещения
cat > /usr/lib/zabbix/alertscripts/send_telegram.sh << 'EOF'
#!/bin/bash
# Отправка оповещений в Telegram
TOKEN="YOUR_BOT_TOKEN"
CHAT_ID="$1"
SUBJECT="$2"
MESSAGE="$3"

curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
    -d chat_id="${CHAT_ID}" \
    -d text="*${SUBJECT}*%0A${MESSAGE}" \
    -d parse_mode="Markdown"
EOF

chmod +x /usr/lib/zabbix/alertscripts/send_telegram.sh

# Создание скрипта резервного копирования конфигурации
log "Создание скрипта резервного копирования..."
cat > /opt/backup-zabbix.sh << EOF
#!/bin/bash
# Скрипт резервного копирования Zabbix
BACKUP_DIR="/backup/zabbix"
DATE=\$(date +%Y%m%d_%H%M%S)

mkdir -p \$BACKUP_DIR

# Резервное копирование базы данных
mysqldump -uzabbix -p$DB_PASSWORD --single-transaction --routines --triggers zabbix | gzip > \$BACKUP_DIR/zabbix_db_\$DATE.sql.gz

# Резервное копирование конфигурации
tar -czf \$BACKUP_DIR/zabbix_config_\$DATE.tar.gz \
    /etc/zabbix \
    /usr/lib/zabbix \
    /usr/share/zabbix

# Удаление старых бэкапов (старше 30 дней)
find \$BACKUP_DIR -name "*.gz" -mtime +30 -delete

echo "Backup completed: \$DATE"
EOF

chmod +x /opt/backup-zabbix.sh

# Создание задачи резервного копирования
echo "0 2 * * * root /opt/backup-zabbix.sh" > /etc/cron.d/zabbix-backup

# Создание информационного файла
cat > /root/zabbix-credentials.txt << EOF
===============================================
         ZABBIX SERVER УСТАНОВЛЕН
===============================================

Доступ к веб-интерфейсу:
URL: http://$SERVER_NAME/zabbix
Имя пользователя: Admin
Пароль: $ZABBIX_ADMIN_PASSWORD

Данные базы данных:
Хост: localhost
База данных: zabbix
Пользователь: zabbix
Пароль: $DB_PASSWORD

Сетевые порты:
80/443 - Веб-интерфейс
10051 - Сервер Zabbix (входящие)
10050 - Агент Zabbix (входящие)

Каталоги:
Конфигурация: /etc/zabbix
Веб-файлы: /usr/share/zabbix
Скрипты: /usr/lib/zabbix
Логи: /var/log/zabbix

Команды управления:
systemctl status zabbix-server
systemctl restart zabbix-agent
tail -f /var/log/zabbix/zabbix_server.log

Резервное копирование: /opt/backup-zabbix.sh

===============================================
ВАЖНО: Измените пароль Admin после первого входа!
===============================================
EOF

# Завершение установки
log "Установка завершена успешно!"
echo ""
echo -e "${GREEN}==============================================${NC}"
echo -e "${GREEN}     УСТАНОВКА ZABBIX ЗАВЕРШЕНА             ${NC}"
echo -e "${GREEN}==============================================${NC}"
echo ""
echo -e "${YELLOW}Данные для доступа:${NC}"
echo -e "Веб-интерфейс: ${GREEN}http://$SERVER_NAME/zabbix${NC}"
echo -e "Пользователь: ${GREEN}Admin${NC}"
echo -e "Пароль: ${GREEN}$ZABBIX_ADMIN_PASSWORD${NC}"
echo ""
echo -e "${YELLOW}Информация сохранена в: /root/zabbix-credentials.txt${NC}"
echo ""
echo -e "${YELLOW}Следующие шаги:${NC}"
echo "1. Зайдите в веб-интерфейс и измените пароль Admin"
echo "2. Настройте уведомления (Email/Telegram)"
echo "3. Добавьте первый хост для мониторинга"
echo "4. Настройте шаблоны мониторинга"
echo ""
echo -e "Лог установки: ${GREEN}/var/log/zabbix-install.log${NC}"
