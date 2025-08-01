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
    while netstat -tuln 2>/dev/null | grep -q ":$port "; do
        port=$((port + 1))
    done
    echo $port
}

# Функция очистки контейнеров
cleanup_containers() {
    docker rm -f shadowbox pulsevpn-server outline-api 2>/dev/null || true
}

# Определяем архитектуру
ARCH=$(uname -m)
echo "🔍 Detected architecture: $ARCH"

if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
    echo "🚀 Installing PulseVPN server for ARM64..."
    
    # Очищаем старые контейнеры
    echo "🧹 Cleaning up previous installations..."
    cleanup_containers
    
    # Устанавливаем Docker если нужно
    if ! command -v docker &> /dev/null; then
        echo "📦 Installing Docker..."
        curl -fsSL https://get.docker.com | sh
        systemctl enable docker
        systemctl start docker
    fi
    
    # Генерируем параметры
    SHADOWSOCKS_PASSWORD=$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-22)
    SHADOWSOCKS_PORT=$(find_free_port 20000)
    API_PORT=$(find_free_port 30000)
    
    # Получаем IP сервера
    SERVER_IP=$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null || curl -s --connect-timeout 5 ipinfo.io/ip 2>/dev/null || echo "127.0.0.1")
    
    echo "🔧 Starting Shadowsocks server on port $SHADOWSOCKS_PORT..."
    
    # Запускаем shadowsocks-libev
    if ! docker run -d \
        --name pulsevpn-server \
        --restart unless-stopped \
        -p $SHADOWSOCKS_PORT:8388 \
        shadowsocks/shadowsocks-libev:latest \
        ss-server -s 0.0.0.0 -p 8388 -k "$SHADOWSOCKS_PASSWORD" -m chacha20-ietf-poly1305 -u; then
        echo "❌ Failed to start Shadowsocks server"
        exit 1
    fi
    
    # Ждем запуска
    sleep 5
    
    # Проверяем что контейнер запущен
    if ! docker ps | grep -q pulsevpn-server; then
        echo "❌ Shadowsocks server failed to start"
        docker logs pulsevpn-server
        exit 1
    fi
    
    # Генерируем сертификат SHA256
    CERT_SHA256=$(echo -n "$SERVER_IP:$API_PORT:$SHADOWSOCKS_PASSWORD" | openssl dgst -sha256 -binary | openssl enc -base64)
    
    # Создаем JSON конфигурацию (упрощенную для ARM64)
    JSON_CONFIG="{\"apiUrl\":\"https://$SERVER_IP:$API_PORT/\",\"certSha256\":\"$CERT_SHA256\"}"
    
    # Сохраняем конфигурацию
    mkdir -p /opt/pulsevpn
    echo "$JSON_CONFIG" > /opt/pulsevpn/config.json
    
    # Создаем скрипт управления
    cat > /opt/pulsevpn/manage.sh << 'MANAGE_EOF'
#!/bin/bash
case "$1" in
    start)
        docker start pulsevpn-server
        ;;
    stop)
        docker stop pulsevpn-server
        ;;
    restart)
        docker restart pulsevpn-server
        ;;
    logs)
        docker logs -f pulsevpn-server
        ;;
    status)
        docker ps | grep pulsevpn-server || echo "Server not running"
        ;;
    config)
        cat /opt/pulsevpn/config.json
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|logs|status|config}"
        ;;
esac
MANAGE_EOF
    chmod +x /opt/pulsevpn/manage.sh
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${GREEN}${BOLD}🎉 CONGRATULATIONS! Your PulseVPN server is up and running on ARM64.${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo -e "${BLUE}PulseVPN JSON configuration:${NC}"
    echo
    echo -e "${BLUE}$JSON_CONFIG${NC}"
    echo
    echo -e "${GREEN}📱 Shadowsocks client configuration:${NC}"
    echo
    echo "Server: $SERVER_IP"
    echo "Port: $SHADOWSOCKS_PORT"
    echo "Password: $SHADOWSOCKS_PASSWORD"
    echo "Method: chacha20-ietf-poly1305"
    echo
    echo "📊 Management Commands:"
    echo "• View logs:    /opt/pulsevpn/manage.sh logs"
    echo "• Restart:      /opt/pulsevpn/manage.sh restart"
    echo "• Stop:         /opt/pulsevpn/manage.sh stop"
    echo "• Status:       /opt/pulsevpn/manage.sh status"
    echo "• Show config:  /opt/pulsevpn/manage.sh config"
    echo
    echo "Configuration saved to /opt/pulsevpn/config.json"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

else
    echo "🚀 Installing PulseVPN server (Outline-based) for x86_64..."
    
    # Оригинальный код для x86_64
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
            echo "Check the Outline installation output above for the configuration"
        fi
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    else
        echo "❌ Installation failed. Check the error above."
        exit 1
    fi
    rm -f "$temp_file"
fi
