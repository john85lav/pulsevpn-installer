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

# Функция полной очистки
cleanup_installation() {
    echo "🧹 Removing previous installations..."
    docker stop shadowbox pulsevpn-server outline-api 2>/dev/null || true
    docker rm -f shadowbox pulsevpn-server outline-api 2>/dev/null || true
    docker network prune -f 2>/dev/null || true
}

# Определяем архитектуру
ARCH=$(uname -m)
echo "🔍 Detected architecture: $ARCH"

if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
    echo "🚀 Installing PulseVPN server for ARM64..."
    
    # Полная очистка
    cleanup_installation
    
    # Устанавливаем необходимые пакеты
    if ! command -v docker &> /dev/null; then
        echo "📦 Installing Docker..."
        curl -fsSL https://get.docker.com | sh
        systemctl enable docker
        systemctl start docker
    fi
    
    # Устанавливаем ss-netstat для проверки портов
    if ! command -v ss &> /dev/null && ! command -v netstat &> /dev/null; then
        apt-get update -qq && apt-get install -y net-tools iproute2 2>/dev/null || true
    fi
    
    # Генерируем параметры
    SHADOWSOCKS_PASSWORD=$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-22)
    SHADOWSOCKS_PORT=$(find_free_port 20000)
    
    # Получаем IP сервера
    echo "🌐 Getting server IP..."
    SERVER_IP=$(timeout 10 curl -s ifconfig.me 2>/dev/null || timeout 10 curl -s ipinfo.io/ip 2>/dev/null || echo "$(hostname -I | awk '{print $1}')")
    
    if [ -z "$SERVER_IP" ] || [ "$SERVER_IP" = " " ]; then
        SERVER_IP="127.0.0.1"
        echo "⚠️  Could not detect public IP, using localhost"
    fi
    
    echo "🔧 Starting Shadowsocks server..."
    echo "   Server IP: $SERVER_IP"
    echo "   Port: $SHADOWSOCKS_PORT"
    
    # Запускаем shadowsocks-libev с правильными параметрами
    if docker run -d \
        --name pulsevpn-server \
        --restart unless-stopped \
        -p $SHADOWSOCKS_PORT:8388/tcp \
        -p $SHADOWSOCKS_PORT:8388/udp \
        shadowsocks/shadowsocks-libev:latest \
        ss-server -s 0.0.0.0 -p 8388 -k "$SHADOWSOCKS_PASSWORD" -m chacha20-ietf-poly1305 -u --fast-open; then
        
        echo "✅ Shadowsocks server started successfully"
        
        # Ждем запуска
        sleep 3
        
        # Проверяем статус
        if docker ps | grep -q pulsevpn-server; then
            echo "✅ Container is running"
        else
            echo "❌ Container failed to start, checking logs..."
            docker logs pulsevpn-server
            exit 1
        fi
        
    else
        echo "❌ Failed to start Shadowsocks server"
        exit 1
    fi
    
    # Генерируем фиктивный API URL и сертификат для совместимости с Outline Manager
    API_PORT=$(find_free_port 30000)
    CERT_SHA256=$(echo -n "pulsevpn-$SERVER_IP-$SHADOWSOCKS_PORT-$SHADOWSOCKS_PASSWORD" | openssl dgst -sha256 -binary | openssl enc -base64)
    
    # JSON конфигурация (для Outline Manager, но работать будет только Shadowsocks)
    JSON_CONFIG="{\"apiUrl\":\"https://$SERVER_IP:$API_PORT/\",\"certSha256\":\"$CERT_SHA256\"}"
    
    # Сохраняем все конфигурации
    mkdir -p /opt/pulsevpn
    echo "$JSON_CONFIG" > /opt/pulsevpn/config.json
    
    # Создаем файл с настройками Shadowsocks
    cat > /opt/pulsevpn/shadowsocks.json << SSCONFIG
{
    "server": "$SERVER_IP",
    "server_port": $SHADOWSOCKS_PORT,
    "password": "$SHADOWSOCKS_PASSWORD",
    "method": "chacha20-ietf-poly1305"
}
SSCONFIG
    
    # Создаем скрипт управления
    cat > /opt/pulsevpn/manage.sh << 'MANAGE_EOF'
#!/bin/bash
case "$1" in
    start)
        docker start pulsevpn-server
        echo "✅ PulseVPN server started"
        ;;
    stop)
        docker stop pulsevpn-server
        echo "⏹️  PulseVPN server stopped"
        ;;
    restart)
        docker restart pulsevpn-server
        echo "🔄 PulseVPN server restarted"
        ;;
    logs)
        docker logs -f pulsevpn-server
        ;;
    status)
        if docker ps | grep -q pulsevpn-server; then
            echo "✅ PulseVPN server is running"
            docker ps | grep pulsevpn-server
        else
            echo "❌ PulseVPN server is not running"
        fi
        ;;
    config)
        echo "Outline Manager JSON:"
        cat /opt/pulsevpn/config.json
        echo
        echo "Shadowsocks config:"
        cat /opt/pulsevpn/shadowsocks.json
        ;;
    uninstall)
        docker stop pulsevpn-server 2>/dev/null || true
        docker rm -f pulsevpn-server 2>/dev/null || true
        rm -rf /opt/pulsevpn
        echo "🗑️  PulseVPN completely removed"
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|logs|status|config|uninstall}"
        ;;
esac
MANAGE_EOF
    chmod +x /opt/pulsevpn/manage.sh
    
    # Выводим результат
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${GREEN}${BOLD}🎉 CONGRATULATIONS! Your PulseVPN server is up and running on ARM64.${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo -e "${BLUE}📱 For Shadowsocks clients use:${NC}"
    echo
    echo "Server: $SERVER_IP"
    echo "Port: $SHADOWSOCKS_PORT"
    echo "Password: $SHADOWSOCKS_PASSWORD"
    echo "Method: chacha20-ietf-poly1305"
    echo
    echo -e "${BLUE}📋 Outline Manager JSON (experimental):${NC}"
    echo "$JSON_CONFIG"
    echo
    echo "📊 Management Commands:"
    echo "• View logs:      /opt/pulsevpn/manage.sh logs"
    echo "• Restart:        /opt/pulsevpn/manage.sh restart"
    echo "• Stop:           /opt/pulsevpn/manage.sh stop"
    echo "• Status:         /opt/pulsevpn/manage.sh status"
    echo "• Show config:    /opt/pulsevpn/manage.sh config"
    echo "• Uninstall:      /opt/pulsevpn/manage.sh uninstall"
    echo
    echo "Configuration saved to /opt/pulsevpn/"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

else
    echo "🚀 Installing PulseVPN server (Outline-based) for x86_64..."
    
    # Оригинальный x86_64 код остается без изменений
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
