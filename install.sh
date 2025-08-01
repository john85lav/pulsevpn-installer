#!/bin/bash
#
# PulseVPN Server One-Line Installer
# Usage: curl -sSL https://raw.githubusercontent.com/john85lav/pulsevpn-installer/main/install.sh | sudo bash
#
set -euo pipefail
# Colors
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'
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

    echo "1024" # fallback
}

# Генерация API пути
generate_api_path() {
    openssl rand -base64 18 | tr -d '=+/' | cut -c1-22
}

# Установка Docker, если не установлен
install_docker_if_needed() {
    if ! command -v docker &> /dev/null; then
        echo "📦 Installing Docker..."
        # Используем официальный установочный скрипт
        if curl -fsSL https://get.docker.com | sh; then
            echo "✅ Docker installed successfully."
            # Включаем и запускаем службу Docker
            if command -v systemctl &> /dev/null; then
                systemctl enable docker 2>/dev/null || true
                systemctl start docker 2>/dev/null || true
                # Небольшая пауза, чтобы служба точно запустилась
                sleep 3
            fi
        else
            echo "❌ Failed to install Docker. Please install Docker manually and try again."
            exit 1
        fi
    else
        echo "🐳 Docker is already installed."
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
        echo "🔧 Installing required packages: ${packages_to_install[*]}..."
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
            echo "⚠️  Unknown package manager. Please install manually: ${packages_to_install[*]}"
        fi
    fi
}

# Запуск контейнера Shadowsocks
run_shadowsocks_container() {
    echo "🔧 Starting Shadowsocks server..."
    
    # Определяем тег образа в зависимости от архитектуры
    local image_tag="latest"
    if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
        # Для ARM64 используем конкретный тег или latest, если multi-arch
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

        echo "✅ Shadowsocks container started"
        sleep 3

        # Проверка, запустился ли контейнер
        if ! docker ps | grep -q pulsevpn-server; then
            echo "❌ Container failed to start. Logs:"
            docker logs pulsevpn-server 2>&1 | tail -n 10 || true
            return 1
        fi
    else
        echo "❌ Failed to start Shadowsocks container"
        return 1
    fi
    return 0
}

# Настройка фаервола
configure_firewall() {
    echo "🔓 Configuring firewall..."
    local firewall_configured=false

    # UFW
    if command -v ufw &> /dev/null; then
        # Проверяем статус UFW
        if ufw status | grep -q 'Status: active'; then
            ufw allow $SHADOWSOCKS_PORT/tcp > /dev/null 2>&1 || true
            ufw allow $SHADOWSOCKS_PORT/udp > /dev/null 2>&1 || true
            echo "✅ UFW rules added for port $SHADOWSOCKS_PORT (TCP and UDP)"
            firewall_configured=true
        else
            echo "⚠️  UFW is installed but not active. Skipping UFW configuration."
        fi
    fi

    # firewalld
    if command -v firewall-cmd &> /dev/null; then
        if firewall-cmd --state 2>/dev/null | grep -q 'running'; then
            firewall-cmd --permanent --add-port=$SHADOWSOCKS_PORT/tcp > /dev/null 2>&1 || true
            firewall-cmd --permanent --add-port=$SHADOWSOCKS_PORT/udp > /dev/null 2>&1 || true
            firewall-cmd --reload > /dev/null 2>&1 || true
            echo "✅ firewalld rules added for port $SHADOWSOCKS_PORT (TCP and UDP)"
            firewall_configured=true
        else
            echo "⚠️  firewalld is installed but not running. Skipping firewalld configuration."
        fi
    fi

    # iptables (fallback и для сохранения правил)
    if command -v iptables &> /dev/null; then
        # Добавляем правила (если они уже есть, iptables не ругается)
        iptables -I INPUT -p tcp --dport $SHADOWSOCKS_PORT -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p udp --dport $SHADOWSOCKS_PORT -j ACCEPT 2>/dev/null || true

        # Пытаемся сохранить правила (разные дистрибутивы по-разному)
        if command -v netfilter-persistent &> /dev/null; then
            netfilter-persistent save > /dev/null 2>&1 || true
            echo "✅ iptables rules saved with netfilter-persistent"
        elif command -v iptables-save &> /dev/null && command -v iptables-restore &> /dev/null; then
            # Пробуем стандартные пути
            if [ -w /etc/iptables/rules.v4 ]; then
                iptables-save > /etc/iptables/rules.v4 2>/dev/null && echo "✅ iptables rules saved to /etc/iptables/rules.v4" || true
            elif [ -w /etc/iptables/rules ]; then
                iptables-save > /etc/iptables/rules 2>/dev/null && echo "✅ iptables rules saved to /etc/iptables/rules" || true
            elif [ -w /etc/sysconfig/iptables ]; then
                 # Для RHEL/CentOS
                iptables-save > /etc/sysconfig/iptables 2>/dev/null && echo "✅ iptables rules saved to /etc/sysconfig/iptables" || true
            else
                 # Последний фолбэк - в /tmp
                iptables-save > /tmp/iptables_rules_backup_"$(date +%s)" 2>/dev/null && echo "⚠️  iptables rules saved to temporary file (no write access to standard paths)" || true
            fi
        else
            echo "⚠️  No tools found to save iptables rules (iptables-save, netfilter-persistent)"
        fi
        
        # Если другие фаерволы не настроены, сообщаем об iptables
        if [ "$firewall_configured" = false ]; then
             echo "✅ iptables rules added for port $SHADOWSOCKS_PORT (TCP and UDP)"
        fi
    else
        echo "⚠️  iptables not found. Please ensure ports are open in your firewall."
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
    JSON_CONFIG="{\"apiUrl\":\"https://$SERVER_IP:$SHADOWSOCKS_PORT/$API_PATH\",\"certSha256\":\"$CERT_SHA256\"}"
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
    echo "Usage: $0 {start|stop|restart|logs|status|config|test|remove}"
    echo
    echo "Commands:"
    echo "  start     - Start the server"
    echo "  stop      - Stop the server"
    echo "  restart   - Restart the server"
    echo "  logs      - Show logs"
    echo "  status    - Show status"
    echo "  config    - Show client settings"
    echo "  test      - Test connection"
    echo "  remove    - Completely remove PulseVPN"
    echo
}

case "$1" in
    start)
        if docker start pulsevpn-server > /dev/null 2>&1; then
            echo -e "${GREEN}✅ Server started${NC}"
        else
            echo -e "${RED}❌ Failed to start server${NC}"
            exit 1
        fi
        ;;
    stop)
        if docker stop pulsevpn-server > /dev/null 2>&1; then
            echo -e "${GREEN}⏹️ Server stopped${NC}"
        else
            echo -e "${RED}❌ Failed to stop server${NC}"
            exit 1
        fi
        ;;
    restart)
        if docker restart pulsevpn-server > /dev/null 2>&1; then
            echo -e "${GREEN}🔄 Server restarted${NC}"
        else
            echo -e "${RED}❌ Failed to restart server${NC}"
            exit 1
        fi
        ;;
    logs)
        docker logs -f pulsevpn-server
        ;;
    status)
        show_header
        if docker ps | grep -q pulsevpn-server; then
            echo -e "${GREEN}✅ PulseVPN Server is running${NC}"
            docker ps | grep pulsevpn-server
            echo
            echo -e "${BOLD}Ports:${NC}"
            docker port pulsevpn-server 2>/dev/null || echo "Port information not available"
        else
            if docker ps -a | grep -q pulsevpn-server; then
                echo -e "${YELLOW}⚠️ PulseVPN Server exists but is stopped${NC}"
                docker ps -a | grep pulsevpn-server
            else
                echo -e "${RED}❌ PulseVPN Server not found${NC}"
            fi
        fi
        ;;
    config)
        show_header
        if [ ! -f /opt/pulsevpn/shadowsocks.json ]; then
            echo -e "${RED}❌ Configuration file not found${NC}"
            exit 1
        fi

        echo -e "${BOLD}📱 Shadowsocks client settings (recommended):${NC}"
        # Читаем значения из файла конфигурации
        SS_SERVER=$(grep '"server"' /opt/pulsevpn/shadowsocks.json | cut -d'"' -f4)
        SS_PORT=$(grep '"server_port"' /opt/pulsevpn/shadowsocks.json | grep -o '[0-9]*')
        SS_PASSWORD=$(grep '"password"' /opt/pulsevpn/shadowsocks.json | cut -d'"' -f4)
        SS_METHOD=$(grep '"method"' /opt/pulsevpn/shadowsocks.json | cut -d'"' -f4)

        echo "Server: $SS_SERVER"
        echo "Port: $SS_PORT"
        echo "Password: $SS_PASSWORD"
        echo "Method: $SS_METHOD"
        echo
        echo -e "${BOLD}📋 Outline Manager JSON (experimental):${NC}"
        if [ -f /opt/pulsevpn/config.json ]; then
            cat /opt/pulsevpn/config.json
        else
            echo "JSON configuration not found."
        fi
        ;;
    test)
        show_header
        echo -e "${BOLD}🧪 Testing connection...${NC}"
        if [ ! -f /opt/pulsevpn/shadowsocks.json ]; then
            echo -e "${RED}❌ Configuration file not found${NC}"
            exit 1
        fi
        SS_SERVER=$(grep '"server"' /opt/pulsevpn/shadowsocks.json | cut -d'"' -f4)
        SS_PORT=$(grep '"server_port"' /opt/pulsevpn/shadowsocks.json | grep -o '[0-9]*')

        if [ "$SS_SERVER" = "127.0.0.1" ] || [ -z "$SS_SERVER" ]; then
            echo -e "${YELLOW}⚠️ Could not determine external IP${NC}"
            SS_SERVER=$(curl -4 -s --max-time 5 api.ipify.org 2>/dev/null || echo "unknown")
            if [ "$SS_SERVER" = "unknown" ]; then
                 SS_SERVER=$(hostname -I | awk '{print $1}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || echo "unknown")
            fi
            if [ "$SS_SERVER" = "unknown" ]; then
                echo -e "${RED}❌ Could not determine IP for testing${NC}"
                exit 1
            fi
            echo "Using IP for test: $SS_SERVER"
        fi

        if [ -n "$SS_PORT" ]; then
            # Используем bash socket для проверки TCP порта
            if timeout 5 bash -c "</dev/tcp/$SS_SERVER/$SS_PORT" 2>/dev/null; then
                echo -e "${GREEN}✅ TCP port $SS_PORT is accessible from $SS_SERVER${NC}"
                echo -e "${GREEN}✅ Server is ready${NC}"
            else
                echo -e "${RED}❌ TCP port $SS_PORT is not accessible${NC}"
                echo -e "${YELLOW}💡 Check your VPS provider's firewall settings${NC}"
                echo -e "${YELLOW}💡 Make sure port $SS_PORT is open for both TCP and UDP${NC}"
            fi
        else
            echo -e "${RED}❌ Could not determine port for testing${NC}"
        fi
        ;;
    remove)
        echo -e "${YELLOW}⚠️ Are you sure you want to remove PulseVPN? (y/N)${NC}"
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
            echo -e "${GREEN}🗑️ PulseVPN completely removed${NC}"
        else
            echo "Removal cancelled."
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
    echo "🚀 Installing PulseVPN server for ARM64..."
    
    # 1. Очистка предыдущих установок
    echo "🧹 Cleaning previous installations..."
    docker stop shadowbox pulsevpn-server outline-api 2>/dev/null || true
    docker rm -f shadowbox pulsevpn-server outline-api 2>/dev/null || true

    # 2. Установка зависимостей
    install_docker_if_needed
    install_required_packages

    # 3. Генерация параметров
    echo "🔧 Generating server parameters..."
    SHADOWSOCKS_PASSWORD=$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-22)
    SHADOWSOCKS_PORT=$(find_free_port)
    API_PATH=$(generate_api_path)
    echo "🌐 Getting server IPv4..."
    SERVER_IP=$(get_ipv4)
    
    echo "   IPv4: $SERVER_IP"
    echo "   Shadowsocks Port: $SHADOWSOCKS_PORT"

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
        echo -e "${GREEN}${BOLD}🎉 PulseVPN Server successfully installed on ARM64!${NC}"
        echo "=================================================================="
        echo
        echo -e "${BLUE}📱 Shadowsocks client settings (recommended):${NC}"
        echo "Server: $SERVER_IP"
        echo "Port: $SHADOWSOCKS_PORT"
        echo "Password: $SHADOWSOCKS_PASSWORD"
        echo "Method: chacha20-ietf-poly1305"
        echo
        echo -e "${BLUE}📋 Outline Manager JSON (experimental):${NC}"
        echo -e "${GREEN}$JSON_CONFIG${NC}"
        echo
        echo -e "${BOLD}📊 Management commands:${NC}"
        echo "• Settings:     sudo /opt/pulsevpn/manage.sh config"
        echo "• Test:         sudo /opt/pulsevpn/manage.sh test"
        echo "• Status:       sudo /opt/pulsevpn/manage.sh status"
        echo "• Logs:         sudo /opt/pulsevpn/manage.sh logs"
        echo "• Restart:      sudo /opt/pulsevpn/manage.sh restart"
        echo "=================================================================="
        echo
    else
        echo "❌ PulseVPN installation for ARM64 failed."
        exit 1
    fi
}

# Установка для x86_64 (оригинальный Outline)
install_for_x86_64() {
    echo "🚀 Installing PulseVPN server (Outline-based) for x86_64..."
    # Temporary file to capture output
    temp_file=$(mktemp)
    # Run Outline installer and capture output
    if sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/Jigsaw-Code/outline-apps/master/server_manager/install_scripts/install_server.sh)" 2>&1 | tee "$temp_file"; then
        echo
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo -e "${GREEN}${BOLD}🎉 CONGRATULATIONS! Your PulseVPN server is up and running.${NC}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo
        # Extract JSON config
        json_config=$(grep -o '{"apiUrl":"[^"]*","certSha256":"[^"]*"}' "$temp_file" | tail -1)
        if [ -n "$json_config" ]; then
            echo -e "${BLUE}PulseVPN JSON configuration:${NC}"
            echo
            echo -e "${BLUE}$json_config${NC}"
            echo
            # Extract server details for manual configuration
            api_url=$(echo "$json_config" | grep -o '"apiUrl":"[^"]*"' | cut -d'"' -f4)
            server_ip=$(echo "$api_url" | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+')
            echo -e "${GREEN}📱 Alternative configurations:${NC}"
            echo
            echo "• Copy JSON above into Outline Manager"
            echo "• Or use any Shadowsocks client with server: $server_ip"
            echo
            # Rename container
            docker rename shadowbox pulsevpn-server 2>/dev/null || true
            # Save config
            mkdir -p /opt/pulsevpn
            echo "$json_config" > /opt/pulsevpn/config.json
            echo "📊 Management Commands:"
            echo "• View logs:    docker logs -f pulsevpn-server"
            echo "• Restart:      docker restart pulsevpn-server"
            echo "• Stop:         docker stop pulsevpn-server"
            echo
            echo "Configuration saved to /opt/pulsevpn/config.json"
        else
            echo "⚠️  Installation completed but JSON not found in output"
            echo "Check the Outline installation output above for the configuration"
        fi
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    else
        echo "❌ Installation failed. Check the error above."
        exit 1
    fi
    # Cleanup
    rm -f "$temp_file"
}

# Основная логика
# Определение архитектуры
ARCH=$(uname -m)
echo "🔍 Detected architecture: $ARCH"

# Выбор метода установки в зависимости от архитектуры
if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
    install_for_arm64
elif [[ "$ARCH" == "x86_64" ]]; then
    install_for_x86_64
else
    echo "❌ Architecture '$ARCH' is not supported by this installer."
    echo "Supported architectures: x86_64, aarch64 (ARM64)."
    exit 1
fi
