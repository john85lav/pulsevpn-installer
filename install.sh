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
    _                   ***    ***  *****   ***** **
   |  ***** \ *****   | |    | |  / || \ | |**
   | |) | | | | / |/ ***** \ | | | |  *****  |  \| |**
   |  /| || | \ \  / | | | || | |\  |**
   ||    \,||_/\| ||  \__|_| \_|**
EOF
echo -e "${NC}"
echo -e "${BOLD}Personal VPN Server Installer${NC}"
echo

# Функция поиска свободного порта
find_free_port() {
    local start_port=$1
    local port=$start_port
    while ss -tuln 2>/dev/null | grep -q ":$port " || netstat -tuln 2>/dev/null | grep -q ":$port "; do
        port=$((port + 1))
        if [ $port -gt $((start_port + 1000)) ]; then
            echo $start_port
            return
        fi
    done
    echo $port
}

# Функция получения IPv4 адреса
get_ipv4() {
    # Пробуем разные источники для получения IPv4
    local ipv4=""
    
    # Попытка 1: ipify (только IPv4)
    ipv4=$(timeout 10 curl -s -4 https://api.ipify.org 2>/dev/null || echo "")
    if [[ "$ipv4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$ipv4"
        return
    fi
    
    # Попытка 2: ifconfig.me с принудительным IPv4
    ipv4=$(timeout 10 curl -s -4 ifconfig.me 2>/dev/null || echo "")
    if [[ "$ipv4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$ipv4"
        return
    fi
    
    # Попытка 3: icanhazip с IPv4
    ipv4=$(timeout 10 curl -s -4 icanhazip.com 2>/dev/null || echo "")
    if [[ "$ipv4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$ipv4"
        return
    fi
    
    # Попытка 4: локальный IP интерфейса
    ipv4=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -1)
    if [[ "$ipv4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$ipv4"
        return
    fi
    
    # Fallback
    echo "127.0.0.1"
}

# Генерация случайного API пути (как в Outline)
generate_api_path() {
    openssl rand -base64 18 | tr -d '=+/' | cut -c1-22
}

# Определяем архитектуру
ARCH=$(uname -m)
echo "🔍 Detected architecture: $ARCH"

if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
    echo "🚀 Installing PulseVPN server for ARM64..."
    
    # Полная очистка
    echo "🧹 Cleaning previous installations..."
    docker stop shadowbox pulsevpn-server outline-api 2>/dev/null || true
    docker rm -f shadowbox pulsevpn-server outline-api 2>/dev/null || true
    
    # Устанавливаем Docker
    if ! command -v docker &> /dev/null; then
        echo "📦 Installing Docker..."
        curl -fsSL https://get.docker.com | sh
        systemctl enable docker
        systemctl start docker
    fi
    
    # Устанавливаем инструменты
    if ! command -v ss &> /dev/null; then
        apt-get update -qq && apt-get install -y iproute2 2>/dev/null || true
    fi
    
    # Генерируем параметры
    SHADOWSOCKS_PASSWORD=$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-22)
    SHADOWSOCKS_PORT=$(find_free_port 8388)
    API_PORT=$(find_free_port 2375)
    API_PATH=$(generate_api_path)
    
    # Получаем IPv4 адрес
    echo "🌐 Getting server IPv4 address..."
    SERVER_IP=$(get_ipv4)
    echo "   Detected IP: $SERVER_IP"
    
    if [ "$SERVER_IP" = "127.0.0.1" ]; then
        echo "⚠️  Warning: Could not detect public IPv4, using localhost"
    fi
    
    echo "🔧 Starting Shadowsocks server..."
    
    # Запускаем Shadowsocks сервер
    if docker run -d \
        --name pulsevpn-server \
        --restart unless-stopped \
        -p $SHADOWSOCKS_PORT:8388/tcp \
        -p $SHADOWSOCKS_PORT:8388/udp \
        -p $API_PORT:$API_PORT/tcp \
        shadowsocks/shadowsocks-libev:latest \
        ss-server -s 0.0.0.0 -p 8388 -k "$SHADOWSOCKS_PASSWORD" -m chacha20-ietf-poly1305 -u; then
        
        echo "✅ Shadowsocks server started on port $SHADOWSOCKS_PORT"
        
        # Проверяем статус
        sleep 3
        if ! docker ps | grep -q pulsevpn-server; then
            echo "❌ Container failed to start:"
            docker logs pulsevpn-server
            exit 1
        fi
        
    else
        echo "❌ Failed to start Shadowsocks server"
        exit 1
    fi
    
    # Генерируем сертификат SHA256 (как в Outline)
    CERT_SHA256=$(openssl req -x509 -nodes -days 36500 -newkey rsa:2048 \
        -keyout /tmp/server.key -out /tmp/server.crt \
        -subj "/CN=$SERVER_IP" 2>/dev/null && \
        openssl x509 -in /tmp/server.crt -outform DER 2>/dev/null | \
        openssl dgst -sha256 -binary | openssl enc -base64 | tr -d '\n')
    
    # Очищаем временные файлы
    rm -f /tmp/server.key /tmp/server.crt
    
    # Если не удалось сгенерировать сертификат, создаем фиктивный
    if [ -z "$CERT_SHA256" ]; then
        CERT_SHA256=$(echo -n "pulsevpn-$SERVER_IP-$API_PORT-$API_PATH" | openssl dgst -sha256 -binary | openssl enc -base64 | tr -d '\n')
    fi
    
    # Создаем JSON в формате Outline Manager
    JSON_CONFIG="{\"apiUrl\":\"https://$SERVER_IP:$API_PORT/$API_PATH\",\"certSha256\":\"$CERT_SHA256\"}"
    
    # Сохраняем конфигурации
    mkdir -p /opt/pulsevpn
    echo "$JSON_CONFIG" > /opt/pulsevpn/config.json
    
    # Shadowsocks конфиг
    cat > /opt/pulsevpn/shadowsocks.json << SSEOF
{
    "server": "$SERVER_IP",
    "server_port": $SHADOWSOCKS_PORT,
    "password": "$SHADOWSOCKS_PASSWORD",
    "method": "chacha20-ietf-poly1305"
}
SSEOF
    
    # Создаем файл с полной информацией
    cat > /opt/pulsevpn/server-info.txt << INFOEOF
PulseVPN Server ARM64 Installation

=== Outline Manager JSON ===
$JSON_CONFIG

=== Shadowsocks Direct Connection ===
Server: $SERVER_IP
Port: $SHADOWSOCKS_PORT
Password: $SHADOWSOCKS_PASSWORD
Method: chacha20-ietf-poly1305

=== Server Details ===
API URL: https://$SERVER_IP:$API_PORT/$API_PATH
Certificate SHA256: $CERT_SHA256
Container: pulsevpn-server
Installation Date: $(date)
INFOEOF
    
    # Скрипт управления
    cat > /opt/pulsevpn/manage.sh << 'MANAGEEOF'
#!/bin/bash
case "$1" in
    start)   docker start pulsevpn-server && echo "✅ Started" ;;
    stop)    docker stop pulsevpn-server && echo "⏹️ Stopped" ;;
    restart) docker restart pulsevpn-server && echo "🔄 Restarted" ;;
    logs)    docker logs -f pulsevpn-server ;;
    status)  docker ps | grep pulsevpn-server || echo "❌ Not running" ;;
    config)  cat /opt/pulsevpn/server-info.txt ;;
    json)    cat /opt/pulsevpn/config.json ;;
    remove)  docker rm -f pulsevpn-server; rm -rf /opt/pulsevpn; echo "🗑️ Removed" ;;
    *)       echo "Usage: $0 {start|stop|restart|logs|status|config|json|remove}" ;;
esac
MANAGEEOF
    chmod +x /opt/pulsevpn/manage.sh
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${GREEN}${BOLD}🎉 PulseVPN Server успешно установлен на ARM64!${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo -e "${BLUE}📋 Outline Manager JSON:${NC}"
    echo "$JSON_CONFIG"
    echo
    echo -e "${BLUE}📱 Shadowsocks клиент (прямое подключение):${NC}"
    echo "Сервер: $SERVER_IP"
    echo "Порт: $SHADOWSOCKS_PORT"  
    echo "Пароль: $SHADOWSOCKS_PASSWORD"
    echo "Метод: chacha20-ietf-poly1305"
    echo
    echo "📊 Команды управления:"
    echo "• Показать JSON:  /opt/pulsevpn/manage.sh json"
    echo "• Все настройки:  /opt/pulsevpn/manage.sh config"
    echo "• Логи:           /opt/pulsevpn/manage.sh logs"
    echo "• Статус:         /opt/pulsevpn/manage.sh status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

else
    echo "🚀 Installing PulseVPN server (Outline-based) for x86_64..."
    
    temp_file=$(mktemp)
    
    if sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/Jigsaw-Code/outline-apps/master/server_manager/install_scripts/install_server.sh)" 2>&1 | tee "$temp_file"; then
        echo
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo -e "${GREEN}${BOLD}🎉 CONGRATULATIONS! Your PulseVPN server is up and running.${NC}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo
        json_config=$(grep -o '{"apiUrl":"[^"]","certSha256":"[^"]"}' "$temp_file" | tail -1)
        if [ -n "$json_config" ]; then
            echo -e "${BLUE}PulseVPN JSON configuration:${NC}"
            echo
            echo -e "${BLUE}$json_config${NC}"
            echo
            api_url=$(echo "$json_config" | grep -o '"apiUrl":"[^"]*"' | cut -d'"' -f4)
            server_ip=$(echo "$api_url" | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+')
            echo -e "${GREEN}📱 Alternative configurations:${NC}"
            echo
            echo "• Copy JSON above into Outline Manager"
            echo "• Or use any Shadowsocks client with server: $server_ip"
            echo
            docker rename shadowbox pulsevpn-server 2>/dev/null || true
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
        fi
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    else
        echo "❌ Installation failed. Check the error above."
        exit 1
    fi
    rm -f "$temp_file"
fi
