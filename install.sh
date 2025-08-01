#!/bin/bash
#
# PulseVPN Server One-Line Installer
# Поддерживает x86_64 (через Outline) и ARM64 (через Shadowsocks-libev)
# Использование: curl -sSL https://raw.githubusercontent.com/john85lav/pulsevpn-installer/main/install.sh | sudo bash
#
set -euo pipefail

# === Константы и цвета ===
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly BOLD='\033[1m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color

# === Глобальные переменные ===
ARCH=""
SERVER_IP=""
SHADOWSOCKS_PORT=""
API_PORT=""
SHADOWSOCKS_PASSWORD=""
API_PATH=""
CERT_SHA256=""
JSON_CONFIG=""
OUTLINE_INSTALLED=false

# === Функции утилиты ===

log() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# === Функции для ARM64 ===

# Функция получения IPv4 адреса
get_ipv4() {
    local ipv4=""
    # Принудительно получаем только IPv4
    ipv4=$(timeout 10 curl -4 -s --max-time 5 api.ipify.org 2>/dev/null || echo "")
    if [[ "$ipv4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$ipv4"
        return
    fi
    ipv4=$(timeout 10 curl -4 -s --max-time 5 ifconfig.me 2>/dev/null || echo "")
    if [[ "$ipv4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$ipv4"
        return
    fi
    ipv4=$(timeout 10 curl -4 -s --max-time 5 icanhazip.com 2>/dev/null || echo "")
    if [[ "$ipv4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$ipv4"
        return
    fi
    # Получаем локальный IPv4 из маршрутизации (fallback)
    ipv4=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") print $(i+1); exit}' | head -1)
    if [[ "$ipv4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$ipv4"
        return
    fi
    log_error "Не удалось определить внешний IPv4 адрес сервера."
    echo "127.0.0.1"
}

# Функция поиска свободного порта
find_free_port() {
    local start_port=${1:-1024}
    local max_attempts=1000
    local port
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        # Генерируем случайный порт в диапазоне 1024-65535
        port=$(( ( RANDOM % 64511 ) + 1025 ))
        # Проверяем, свободен ли порт
        if ! (ss -tuln 2>/dev/null | grep -q ":$port " || netstat -tuln 2>/dev/null | grep -q ":$port "); then
            echo $port
            return 0
        fi
        attempt=$((attempt + 1))
    done

    # Если не нашли случайный, пробуем линейный поиск от стартового
    port=$start_port
    while [ $port -le 65535 ]; do
        if ! (ss -tuln 2>/dev/null | grep -q ":$port " || netstat -tuln 2>/dev/null | grep -q ":$port "); then
            echo $port
            return 0
        fi
        port=$((port + 1))
    done

    log_error "Не удалось найти свободный порт после $max_attempts попыток."
    exit 1
}

# Генерация API пути
generate_api_path() {
    openssl rand -base64 18 | tr -d '=+/' | cut -c1-22
}

# Установка Docker, если не установлен
install_docker_if_needed() {
    if ! command -v docker &> /dev/null; then
        log "Docker не найден. Устанавливаем Docker..."
        # Используем официальный установочный скрипт
        if curl -fsSL https://get.docker.com | sh; then
            log_success "Docker успешно установлен."
            # Включаем и запускаем службу Docker
            if command -v systemctl &> /dev/null; then
                systemctl enable docker 2>/dev/null || true
                systemctl start docker 2>/dev/null || true
                # Небольшая пауза, чтобы служба точно запустилась
                sleep 3
            fi
        else
            log_error "Ошибка установки Docker. Пожалуйста, установите Docker вручную и повторите попытку."
            exit 1
        fi
    else
        log "Docker уже установлен."
    fi
}

# Установка необходимых утилит
install_required_packages() {
    # Проверяем и устанавливаем ss, nc, curl, openssl, iptables
    local packages_to_install=()

    if ! command -v ss &> /dev/null; then
        packages_to_install+=(iproute2)
    fi
    if ! command -v nc &> /dev/null && ! command -v netcat &> /dev/null; then
        packages_to_install+=(netcat-openbsd) # Или netcat-traditional, но openbsd более распространён
    fi
    if ! command -v curl &> /dev/null; then
        packages_to_install+=(curl)
    fi
    if ! command -v openssl &> /dev/null; then
        packages_to_install+=(openssl)
    fi
    if ! command -v iptables &> /dev/null; then
        packages_to_install+=(iptables)
    fi

    if [ ${#packages_to_install[@]} -gt 0 ]; then
        log "Установка необходимых пакетов: ${packages_to_install[*]}..."
        # Пробуем разные менеджеры пакетов
        if command -v apt-get &> /dev/null; then
            apt-get update -qq && apt-get install -y "${packages_to_install[@]}" < /dev/null 2>/dev/null || true
        elif command -v yum &> /dev/null; then
            yum install -y "${packages_to_install[@]}" < /dev/null 2>/dev/null || true
        elif command -v dnf &> /dev/null; then
            dnf install -y "${packages_to_install[@]}" < /dev/null 2>/dev/null || true
        elif command -v apk &> /dev/null; then
            apk add --no-cache "${packages_to_install[@]}" < /dev/null 2>/dev/null || true
        else
            log_warn "Неизвестный менеджер пакетов. Установите вручную: ${packages_to_install[*]}"
        fi
    fi
}

# Запуск контейнера Shadowsocks
run_shadowsocks_container() {
    log "Запуск контейнера Shadowsocks..."

    # Определяем тег образа в зависимости от архитектуры
    local image_tag="latest"
    if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
        # Для ARM64 используем конкретный тег или latest, если multi-arch
        # shadowsocks/shadowsocks-libev имеет поддержку multi-arch
        image_tag="latest"
    fi

    if docker run -d \
        --name pulsevpn-server \
        --restart unless-stopped \
        --log-driver local \
        -p $SHADOWSOCKS_PORT:8388/tcp \
        -p $SHADOWSOCKS_PORT:8388/udp \
        "shadowsocks/shadowsocks-libev:$image_tag" \
        ss-server -s 0.0.0.0 -p 8388 -k "$SHADOWSOCKS_PASSWORD" -m chacha20-ietf-poly1305 -u --fast-open -t 300; then

        log_success "Контейнер Shadowsocks запущен."
        sleep 3

        # Проверка, запустился ли контейнер
        if ! docker ps | grep -q pulsevpn-server; then
            log_error "Контейнер не запущен. Логи контейнера:"
            docker logs pulsevpn-server 2>&1 | tail -n 10 || true
            return 1
        fi
    else
        log_error "Ошибка запуска контейнера Shadowsocks."
        return 1
    fi
    return 0
}

# Настройка фаервола
configure_firewall() {
    log "Настройка фаервола..."
    local firewall_configured=false

    # UFW
    if command -v ufw &> /dev/null; then
        # Проверяем статус UFW
        if ufw status | grep -q 'Status: active'; then
            ufw allow $SHADOWSOCKS_PORT/tcp > /dev/null 2>&1 || true
            ufw allow $SHADOWSOCKS_PORT/udp > /dev/null 2>&1 || true
            # API порт не нужен для этой конфигурации, но оставим на случай
            # ufw allow $API_PORT/tcp > /dev/null 2>&1 || true
            log_success "Правила UFW добавлены для порта $SHADOWSOCKS_PORT (TCP и UDP)."
            firewall_configured=true
        else
            log_warn "UFW установлен, но не активен. Пропуск настройки UFW."
        fi
    fi

    # firewalld
    if command -v firewall-cmd &> /dev/null; then
        if firewall-cmd --state 2>/dev/null | grep -q 'running'; then
            firewall-cmd --permanent --add-port=$SHADOWSOCKS_PORT/tcp > /dev/null 2>&1 || true
            firewall-cmd --permanent --add-port=$SHADOWSOCKS_PORT/udp > /dev/null 2>&1 || true
            firewall-cmd --reload > /dev/null 2>&1 || true
            log_success "Правила firewalld добавлены для порта $SHADOWSOCKS_PORT (TCP и UDP)."
            firewall_configured=true
        else
            log_warn "firewalld установлен, но не запущен. Пропуск настройки firewalld."
        fi
    fi

    # iptables (fallback и для сохранения правил)
    if command -v iptables &> /dev/null; then
        # Добавляем правила (если они уже есть, iptables не ругается)
        iptables -I INPUT -p tcp --dport $SHADOWSOCKS_PORT -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p udp --dport $SHADOWSOCKS_PORT -j ACCEPT 2>/dev/null || true
        # iptables -I INPUT -p tcp --dport $API_PORT -j ACCEPT 2>/dev/null || true

        # Пытаемся сохранить правила (разные дистрибутивы по-разному)
        if command -v netfilter-persistent &> /dev/null; then
            netfilter-persistent save > /dev/null 2>&1 || true
            log_success "Правила iptables сохранены с помощью netfilter-persistent."
        elif command -v iptables-save &> /dev/null && command -v iptables-restore &> /dev/null; then
            # Пробуем стандартные пути
            if [ -w /etc/iptables/rules.v4 ]; then
                iptables-save > /etc/iptables/rules.v4 2>/dev/null && log_success "Правила iptables сохранены в /etc/iptables/rules.v4." || true
            elif [ -w /etc/iptables/rules ]; then
                iptables-save > /etc/iptables/rules 2>/dev/null && log_success "Правила iptables сохранены в /etc/iptables/rules." || true
            elif [ -w /etc/sysconfig/iptables ]; then
                 # Для RHEL/CentOS
                iptables-save > /etc/sysconfig/iptables 2>/dev/null && log_success "Правила iptables сохранены в /etc/sysconfig/iptables." || true
            else
                 # Последний фолбэк - в /tmp
                iptables-save > /tmp/iptables_rules_backup_"$(date +%s)" 2>/dev/null && log_warn "Правила iptables сохранены во временный файл (нет прав на стандартные пути)." || true
            fi
        else
            log_warn "Не найдены инструменты для сохранения правил iptables (iptables-save, netfilter-persistent)."
        fi
        # Если другие фаерволы не настроены, сообщаем об iptables
        if [ "$firewall_configured" = false ]; then
             log_success "Правила iptables добавлены для порта $SHADOWSOCKS_PORT (TCP и UDP)."
        fi
    else
        log_warn "iptables не найден. Убедитесь, что порты открыты в вашем фаерволе."
    fi
}

# Генерация фиктивного SHA256 для совместимости с Outline Manager
generate_fake_cert_sha256() {
    # Генерируем уникальную, но детерминированную строку на основе IP и порта
    local data_to_hash="${SERVER_IP}:${SHADOWSOCKS_PORT}:${API_PATH}"
    CERT_SHA256=$(echo -n "$data_to_hash" | openssl dgst -sha256 -hex | sed 's/.* //')
    # Убедимся, что это заглавные буквы, как в настоящем сертификате
    CERT_SHA256=$(echo "$CERT_SHA256" | tr 'a-f' 'A-F')
}

# Сохранение конфигураций
save_arm64_configs() {
    mkdir -p /opt/pulsevpn

    # JSON конфигурация в формате Outline Manager
    JSON_CONFIG="{\"apiUrl\":\"https://$SERVER_IP:$API_PORT/$API_PATH\",\"certSha256\":\"$CERT_SHA256\"}"
    echo "$JSON_CONFIG" > /opt/pulsevpn/config.json

    # Shadowsocks конфиг для прямого подключения
    cat > /opt/pulsevpn/shadowsocks.json << EOF
{
    "server": "$SERVER_IP",
    "server_port": $SHADOWSOCKS_PORT,
    "password": "$SHADOWSOCKS_PASSWORD",
    "method": "chacha20-ietf-poly1305"
}
EOF

    # Создаем скрипт управления
    cat > /opt/pulsevpn/manage.sh << 'EOF_SCRIPT'
#!/bin/bash
set -euo pipefail

# Цвета
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly BOLD='\033[1m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color

show_header() {
    echo -e "${BLUE}${BOLD}PulseVPN Manager${NC}"
    echo "========================"
}

show_usage() {
    echo "Использование: $0 {start|stop|restart|logs|status|config|test|remove}"
    echo
    echo "Команды:"
    echo "  start     - Запустить сервер"
    echo "  stop      - Остановить сервер"
    echo "  restart   - Перезапустить сервер"
    echo "  logs      - Показать логи"
    echo "  status    - Показать статус"
    echo "  config    - Показать настройки для клиентов"
    echo "  test      - Протестировать соединение"
    echo "  remove    - Полностью удалить PulseVPN"
    echo
}

case "$1" in
    start)
        if docker start pulsevpn-server > /dev/null 2>&1; then
            echo -e "${GREEN}✅ Сервер запущен${NC}"
        else
            echo -e "${RED}❌ Ошибка запуска сервера${NC}"
            exit 1
        fi
        ;;
    stop)
        if docker stop pulsevpn-server > /dev/null 2>&1; then
            echo -e "${GREEN}⏹️ Сервер остановлен${NC}"
        else
            echo -e "${RED}❌ Ошибка остановки сервера${NC}"
            exit 1
        fi
        ;;
    restart)
        if docker restart pulsevpn-server > /dev/null 2>&1; then
            echo -e "${GREEN}🔄 Сервер перезапущен${NC}"
        else
            echo -e "${RED}❌ Ошибка перезапуска сервера${NC}"
            exit 1
        fi
        ;;
    logs)
        docker logs -f pulsevpn-server
        ;;
    status)
        show_header
        if docker ps | grep -q pulsevpn-server; then
            echo -e "${GREEN}✅ PulseVPN Server запущен${NC}"
            docker ps | grep pulsevpn-server
            echo
            echo -e "${BOLD}Порты:${NC}"
            docker port pulsevpn-server 2>/dev/null || echo "Информация о портах недоступна"
        else
            if docker ps -a | grep -q pulsevpn-server; then
                echo -e "${YELLOW}⚠️ PulseVPN Server существует, но остановлен${NC}"
                docker ps -a | grep pulsevpn-server
            else
                echo -e "${RED}❌ PulseVPN Server не найден${NC}"
            fi
        fi
        ;;
    config)
        show_header
        if [ ! -f /opt/pulsevpn/shadowsocks.json ]; then
            echo -e "${RED}❌ Файл конфигурации не найден${NC}"
            exit 1
        fi

        echo -e "${BOLD}📱 Настройки для Shadowsocks клиентов (рекомендуется):${NC}"
        # Читаем значения из файла конфигурации
        SS_SERVER=$(grep '"server"' /opt/pulsevpn/shadowsocks.json | cut -d'"' -f4)
        SS_PORT=$(grep '"server_port"' /opt/pulsevpn/shadowsocks.json | grep -o '[0-9]*')
        SS_PASSWORD=$(grep '"password"' /opt/pulsevpn/shadowsocks.json | cut -d'"' -f4)
        SS_METHOD=$(grep '"method"' /opt/pulsevpn/shadowsocks.json | cut -d'"' -f4)

        echo "Сервер: $SS_SERVER"
        echo "Порт: $SS_PORT"
        echo "Пароль: $SS_PASSWORD"
        echo "Метод: $SS_METHOD"
        echo
        echo -e "${BOLD}📋 Outline Manager JSON (экспериментально):${NC}"
        if [ -f /opt/pulsevpn/config.json ]; then
            cat /opt/pulsevpn/config.json
        else
            echo "JSON конфигурация не найдена."
        fi
        ;;
    test)
        show_header
        echo -e "${BOLD}🧪 Тестирование соединения...${NC}"
        if [ ! -f /opt/pulsevpn/shadowsocks.json ]; then
            echo -e "${RED}❌ Файл конфигурации не найден${NC}"
            exit 1
        fi
        SS_SERVER=$(grep '"server"' /opt/pulsevpn/shadowsocks.json | cut -d'"' -f4)
        SS_PORT=$(grep '"server_port"' /opt/pulsevpn/shadowsocks.json | grep -o '[0-9]*')

        if [ "$SS_SERVER" = "127.0.0.1" ] || [ -z "$SS_SERVER" ]; then
            echo -e "${YELLOW}⚠️ Не удалось определить внешний IP сервера${NC}"
            SS_SERVER=$(curl -4 -s --max-time 5 api.ipify.org 2>/dev/null || echo "unknown")
            if [ "$SS_SERVER" = "unknown" ]; then
                 SS_SERVER=$(hostname -I | awk '{print $1}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || echo "unknown")
            fi
            if [ "$SS_SERVER" = "unknown" ]; then
                echo -e "${RED}❌ Не удалось определить IP для тестирования${NC}"
                exit 1
            fi
            echo "Используется IP для теста: $SS_SERVER"
        fi

        if [ -n "$SS_PORT" ]; then
            # Используем bash socket для проверки TCP порта
            if timeout 5 bash -c "</dev/tcp/$SS_SERVER/$SS_PORT" 2>/dev/null; then
                echo -e "${GREEN}✅ TCP порт $SS_PORT доступен с $SS_SERVER${NC}"
                echo -e "${GREEN}✅ Сервер готов к работе${NC}"
            else
                echo -e "${RED}❌ TCP порт $SS_PORT недоступен${NC}"
                echo -e "${YELLOW}💡 Проверьте настройки фаерволла вашего VPS провайдера${NC}"
                echo -e "${YELLOW}💡 Убедитесь, что порт $SS_PORT открыт для TCP и UDP${NC}"
            fi
        else
            echo -e "${RED}❌ Не удалось определить порт для тестирования${NC}"
        fi
        ;;
    remove)
        echo -e "${YELLOW}⚠️ Вы уверены, что хотите удалить PulseVPN? (y/N)${NC}"
        read -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            docker rm -f pulsevpn-server > /dev/null 2>&1 || true
            # Удаляем правила iptables (если были добавлены)
            if command -v iptables &> /dev/null; then
                SS_PORT_FILE="/opt/pulsevpn/shadowsocks.json"
                if [ -f "$SS_PORT_FILE" ]; then
                    OLD_SS_PORT=$(grep '"server_port"' "$SS_PORT_FILE" | grep -o '[0-9]*')
                    if [ -n "$OLD_SS_PORT" ]; then
                        iptables -D INPUT -p tcp --dport $OLD_SS_PORT -j ACCEPT 2>/dev/null || true
                        iptables -D INPUT -p udp --dport $OLD_SS_PORT -j ACCEPT 2>/dev/null || true
                        # Пытаемся сохранить изменения
                        if command -v netfilter-persistent &> /dev/null; then
                            netfilter-persistent save > /dev/null 2>&1 || true
                        elif command -v iptables-save &> /dev/null; then
                             # Пробуем стандартные пути
                            if [ -w /etc/iptables/rules.v4 ]; then
                                iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
                            elif [ -w /etc/iptables/rules ]; then
                                iptables-save > /etc/iptables/rules 2>/dev/null || true
                            fi
                        fi
                    fi
                fi
            fi
            rm -rf /opt/pulsevpn
            echo -e "${GREEN}🗑️ PulseVPN полностью удален${NC}"
        else
            echo "Удаление отменено."
        fi
        ;;
    *)
        show_header
        show_usage
        ;;
esac
EOF_SCRIPT
    chmod +x /opt/pulsevpn/manage.sh
}

# Установка для ARM64
install_for_arm64() {
    log "Начинаем установку PulseVPN для архитектуры ARM64..."

    # 1. Очистка предыдущих установок
    log "Очистка предыдущих установок..."
    docker stop shadowbox pulsevpn-server outline-api 2>/dev/null || true
    docker rm -f shadowbox pulsevpn-server outline-api 2>/dev/null || true

    # 2. Установка зависимостей
    install_docker_if_needed
    install_required_packages

    # 3. Генерация параметров
    log "Генерация параметров сервера..."
    SHADOWSOCKS_PASSWORD=$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-22)
    SHADOWSOCKS_PORT=$(find_free_port)
    API_PORT=$(find_free_port) # Не используется напрямую, но для JSON
    API_PATH=$(generate_api_path)
    SERVER_IP=$(get_ipv4)

    log "Параметры сервера:"
    log "  IPv4: $SERVER_IP"
    log "  Shadowsocks Port: $SHADOWSOCKS_PORT"
    log "  API Port (для JSON): $API_PORT"
    log "  API Path (для JSON): $API_PATH"

    # 4. Запуск контейнера
    if run_shadowsocks_container; then
        # 5. Настройка фаервола
        configure_firewall

        # 6. Генерация конфигураций
        generate_fake_cert_sha256
        save_arm64_configs

        # 7. Вывод финального сообщения
        echo
        echo "=================================================================="
        echo -e "${GREEN}${BOLD}🎉 PulseVPN Server успешно установлен на ARM64!${NC}"
        echo "=================================================================="
        echo
        echo -e "${BLUE}📱 Настройки для Shadowsocks клиентов (рекомендуется):${NC}"
        echo "Сервер: $SERVER_IP"
        echo "Порт: $SHADOWSOCKS_PORT"
        echo "Пароль: $SHADOWSOCKS_PASSWORD"
        echo "Метод: chacha20-ietf-poly1305"
        echo
        echo -e "${BLUE}📋 Outline Manager JSON (экспериментально):${NC}"
        echo -e "${GREEN}$JSON_CONFIG${NC}"
        echo
        echo -e "${BOLD}📊 Команды управления:${NC}"
        echo "• Настройки:   sudo /opt/pulsevpn/manage.sh config"
        echo "• Тест связи:  sudo /opt/pulsevpn/manage.sh test"
        echo "• Статус:      sudo /opt/pulsevpn/manage.sh status"
        echo "• Логи:        sudo /opt/pulsevpn/manage.sh logs"
        echo "• Перезапуск:  sudo /opt/pulsevpn/manage.sh restart"
        echo "=================================================================="
        echo
    else
        log_error "Установка PulseVPN для ARM64 завершена с ошибкой."
        exit 1
    fi
}


# === Функции для x86_64 (оригинальный Outline) ===

# Установка для x86_64
install_for_x86_64() {
    log "Начинаем установку PulseVPN для архитектуры x86_64 (через Outline)..."

    # Временный файл для захвата вывода
    temp_file=$(mktemp)
    # Для очистки в случае ошибки
    outline_log_file=""

    # Запуск установщика Outline и захват вывода
    # Используем || true, чтобы не прерывать скрипт сразу, а обработать ошибку ниже
    set +e # Временно отключаем set -e
    sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/Jigsaw-Code/outline-apps/master/server_manager/install_scripts/install_server.sh)" 2>&1 | tee "$temp_file"
    local install_exit_code=${PIPESTATUS[0]}
    set -e # Включаем обратно

    if [ $install_exit_code -eq 0 ]; then
        log_success "Установщик Outline завершился успешно."
        OUTLINE_INSTALLED=true

        # Извлечение JSON конфига
        # Ищем строку с поздравлением, а затем JSON в следующих строках
        # Более надежный способ, чем простой grep
        json_config=$(awk '/CONGRATULATIONS! Your Outline server is up and running/,0' "$temp_file" | grep -o '{[^}]*"apiUrl":"[^"]*"[^}]*"certSha256":"[A-Fa-f0-9]*"[^}]*}' | tail -1)

        if [ -n "$json_config" ]; then
            log_success "Конфигурация Outline успешно извлечена."

            # Переименовываем контейнер
            docker rename shadowbox pulsevpn-server 2>/dev/null || true

            # Сохраняем конфиг
            mkdir -p /opt/pulsevpn
            echo "$json_config" > /opt/pulsevpn/config.json

            # Создаем скрипт управления для x86_64
            cat > /opt/pulsevpn/manage.sh << 'EOF_X86_SCRIPT'
#!/bin/bash
set -euo pipefail

# Цвета
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly BOLD='\033[1m'
readonly RED='\033[0;31m'
readonly NC='\033[0m' # No Color

show_header() {
    echo -e "${BLUE}${BOLD}PulseVPN Manager (Outline)${NC}"
    echo "==============================="
}

show_usage() {
    echo "Использование: $0 {start|stop|restart|logs|status|config|test|remove}"
    echo
    echo "Команды:"
    echo "  start     - Запустить сервер"
    echo "  stop      - Остановить сервер"
    echo "  restart   - Перезапустить сервер"
    echo "  logs      - Показать логи"
    echo "  status    - Показать статус"
    echo "  config    - Показать конфигурацию JSON"
    echo "  test      - Протестировать API"
    echo "  remove    - Удалить PulseVPN (только контейнер и конфиг)"
    echo
}

case "$1" in
    start)
        if docker start pulsevpn-server > /dev/null 2>&1; then
            echo -e "${GREEN}✅ Сервер запущен${NC}"
        else
            echo -e "${RED}❌ Ошибка запуска сервера${NC}"
            exit 1
        fi
        ;;
    stop)
        if docker stop pulsevpn-server > /dev/null 2>&1; then
            echo -e "${GREEN}⏹️ Сервер остановлен${NC}"
        else
            echo -e "${RED}❌ Ошибка остановки сервера${NC}"
            exit 1
        fi
        ;;
    restart)
        if docker restart pulsevpn-server > /dev/null 2>&1; then
            echo -e "${GREEN}🔄 Сервер перезапущен${NC}"
        else
            echo -e "${RED}❌ Ошибка перезапуска сервера${NC}"
            exit 1
        fi
        ;;
    logs)
        docker logs -f pulsevpn-server
        ;;
    status)
        show_header
        if docker ps | grep -q pulsevpn-server; then
            echo -e "${GREEN}✅ PulseVPN Server запущен${NC}"
            docker ps | grep pulsevpn-server
        else
            if docker ps -a | grep -q pulsevpn-server; then
                echo -e "${YELLOW}⚠️ PulseVPN Server существует, но остановлен${NC}"
                docker ps -a | grep pulsevpn-server
            else
                echo -e "${RED}❌ PulseVPN Server не найден${NC}"
            fi
        fi
        ;;
    config)
        show_header
        if [ -f /opt/pulsevpn/config.json ]; then
            echo -e "${BOLD}Конфигурация Outline Manager:${NC}"
            cat /opt/pulsevpn/config.json
            echo
            echo "Скопируйте JSON выше в Outline Manager."
        else
            echo -e "${RED}❌ Конфигурационный файл не найден${NC}"
        fi
        ;;
    test)
        show_header
        echo -e "${BOLD}🧪 Тестирование API Outline...${NC}"
        if [ -f /opt/pulsevpn/config.json ]; then
            API_URL=$(grep -o '"apiUrl":"[^"]*"' /opt/pulsevpn/config.json | cut -d'"' -f4)
            if [ -n "$API_URL" ]; then
                if curl -k -s --connect-timeout 5 --max-time 10 "$API_URL" > /dev/null 2>&1; then
                    echo -e "${GREEN}✅ API Outline доступен${NC}"
                else
                    echo -e "${RED}❌ API Outline недоступен${NC}"
                    echo -e "${YELLOW}💡 Проверьте настройки фаерволла${NC}"
                fi
            else
                echo -e "${RED}❌ Не удалось извлечь URL API из конфигурации${NC}"
            fi
        else
            echo -e "${RED}❌ Конфигурационный файл не найден${NC}"
        fi
        ;;
    remove)
        echo -e "${YELLOW}⚠️ Вы уверены, что хотите удалить PulseVPN? (y/N)${NC}"
        read -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            docker rm -f pulsevpn-server > /dev/null 2>&1 || true
            rm -rf /opt/pulsevpn
            echo -e "${GREEN}🗑️ PulseVPN удален${NC}"
        else
            echo "Удаление отменено."
        fi
        ;;
    *)
        show_header
        show_usage
        ;;
esac
EOF_X86_SCRIPT
            chmod +x /opt/pulsevpn/manage.sh

            # Извлечение IP для отображения
            api_url=$(echo "$json_config" | grep -o '"apiUrl":"[^"]*"' | cut -d'"' -f4)
            server_ip=$(echo "$api_url" | sed -E 's#https?://([^:/]+).*#\1#')

            # Финальный вывод
            echo
            echo "=================================================================="
            echo -e "${GREEN}${BOLD}🎉 CONGRATULATIONS! Your PulseVPN server is up and running.${NC}"
            echo "=================================================================="
            echo
            echo -e "${BLUE}PulseVPN JSON configuration:${NC}"
            echo
            echo -e "${GREEN}$json_config${NC}"
            echo
            echo -e "${GREEN}📱 Альтернативные конфигурации:${NC}"
            echo
            echo "• Скопируйте JSON выше в Outline Manager"
            echo "• Или используйте любой Shadowsocks клиент с сервером: $server_ip"
            echo
            echo -e "${BOLD}📊 Команды управления:${NC}"
            echo "• Просмотр логов:    sudo /opt/pulsevpn/manage.sh logs"
            echo "• Перезапуск:        sudo /opt/pulsevpn/manage.sh restart"
            echo "• Остановка:         sudo /opt/pulsevpn/manage.sh stop"
            echo "• Конфигурация:      sudo /opt/pulsevpn/manage.sh config"
            echo "• Тест API:          sudo /opt/pulsevpn/manage.sh test"
            echo
            echo "Конфигурация сохранена в /opt/pulsevpn/config.json"
            echo "=================================================================="

        else
            log_error "Установка завершена, но не удалось найти JSON конфигурацию в выводе."
            log "Проверьте вывод установщика выше. Лог сохранен в $temp_file"
            # Не завершаем с ошибкой, так как сервер мог запуститься
        fi
    else
        log_error "Установка PulseVPN (Outline) завершена с ошибкой (код выхода: $install_exit_code)."
        log "Полный лог установки находится в файле: $temp_file"
        # Пытаемся найти лог от самого Outline-скрипта
        outline_log_file=$(grep -o '/tmp/outline_log[a-zA-Z0-9]*' "$temp_file" | head -1)
        if [ -n "$outline_log_file" ] && [ -f "$outline_log_file" ]; then
            log "Детальный лог установщика Outline: $outline_log_file"
            log "--- Начало лога Outline ---"
            cat "$outline_log_file"
            log "--- Конец лога Outline ---"
        fi
        # Очищаем, так как установка неудачна
        rm -f "$temp_file"
        exit 1
    fi
    # Очистка временного файла в случае успеха
    rm -f "$temp_file"
}


# === Основная логика ===

main() {
    # Приветствие и определение архитектуры
    echo -e "${BLUE}${BOLD}"
    cat << 'EOF'
    ____        __           _    ____  _   _
   |  _ \ _   _| |___  ___  | |  / ___|| \ | |
   | |_) | | | | / __|/ _ \ | | | |  _  |  \| |
   |  __/| |_| | \__ \  __/ | | | |_| | |\  |
   |_|    \__,_|_|___/\___| |_|  \____|_| \_|
EOF
    echo -e "${NC}"
    echo -e "${BOLD}Personal VPN Server Installer${NC}"
    echo

    # Определение архитектуры
    ARCH=$(uname -m)
    log "Обнаруженная архитектура: $ARCH"

    # Выбор метода установки в зависимости от архитектуры
    if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
        install_for_arm64
    elif [[ "$ARCH" == "x86_64" ]]; then
        install_for_x86_64
    else
        log_error "Архитектура '$ARCH' не поддерживается этим установщиком."
        log "Поддерживаемые архитектуры: x86_64, aarch64 (ARM64)."
        exit 1
    fi
}

# Запуск основной функции
main "$@"
