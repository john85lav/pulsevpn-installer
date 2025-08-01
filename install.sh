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

# Функция получения IPv4 адреса
get_ipv4() {
    local ipv4=""
    
    # Принудительно получаем только IPv4
    ipv4=$(timeout 10 curl -4 -s api.ipify.org 2>/dev/null || echo "")
    if [[ "$ipv4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$ipv4"
        return
    fi
    
    ipv4=$(timeout 10 curl -4 -s ifconfig.me 2>/dev/null || echo "")
    if [[ "$ipv4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$ipv4"
        return
    fi
    
    ipv4=$(timeout 10 curl -4 -s icanhazip.com 2>/dev/null || echo "")
    if [[ "$ipv4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$ipv4"
        return
    fi
    
    # Получаем локальный IPv4 из маршрутизации
    ipv4=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -1)
    if [[ "$ipv4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$ipv4"
        return
    fi
    
    echo "127.0.0.1"
}

# Функция поиска свободного порта
find_free_port() {
    local start_port=$1
    local port=$start_port
    while ss -tuln 2>/dev/null | grep -q ":$port " || netstat -tuln 2>/dev/null | grep -q ":$port "; do
        port=$((port + 1))
        if [ $port -gt $((start_port + 500)) ]; then
            echo $start_port
            return
        fi
    done
    echo $port
}

# Генерация API пути
generate_api_path() {
    openssl rand -base64 18 | tr -d '=+/' | cut -c1-22
}

# Определяем архитектуру
ARCH=$(uname -m)
echo "🔍 Detected architecture: $ARCH"

if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
    echo "🚀 Installing PulseVPN server for ARM64..."
    
    # Очистка
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
    
    # Генерируем параметры
    SHADOWSOCKS_PASSWORD=$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-22)
    SHADOWSOCKS_PORT=$(find_free_port 8388)
    API_PORT=$(find_free_port 2375)
    API_PATH=$(generate_api_path)
    
    # Получаем IPv4 адрес
    echo "🌐 Getting server IPv4..."
    SERVER_IP=$(get_ipv4)
    
    echo "   IPv4: $SERVER_IP"
    echo "   Shadowsocks Port: $SHADOWSOCKS_PORT"
    echo "   API Port: $API_PORT"
    
    # Запускаем Shadowsocks
    echo "🔧 Starting Shadowsocks server..."
    if docker run -d \
        --name pulsevpn-server \
        --restart unless-stopped \
        -p $SHADOWSOCKS_PORT:8388/tcp \
        -p $SHADOWSOCKS_PORT:8388/udp \
        shadowsocks/shadowsocks-libev:latest \
        ss-server -s 0.0.0.0 -p 8388 -k "$SHADOWSOCKS_PASSWORD" -m chacha20-ietf-poly1305 -u; then
        
        echo "✅ Container started"
        sleep 3
        
        if ! docker ps | grep -q pulsevpn-server; then
            echo "❌ Container failed:"
            docker logs pulsevpn-server
            exit 1
        fi
        
        # Автоматически открываем порты в фаерволле
        echo "🔓 Configuring firewall..."
        
        # UFW правила
        if command -v ufw &> /dev/null; then
            ufw allow $SHADOWSOCKS_PORT/tcp >/dev/null 2>&1 || true
            ufw allow $SHADOWSOCKS_PORT/udp >/dev/null 2>&1 || true
            ufw allow $API_PORT/tcp >/dev/null 2>&1 || true
            echo "✅ UFW rules added for ports $SHADOWSOCKS_PORT, $API_PORT"
        fi
        
        # iptables правила (fallback)
        iptables -I INPUT -p tcp --dport $SHADOWSOCKS_PORT -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p udp --dport $SHADOWSOCKS_PORT -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p tcp --dport $API_PORT -j ACCEPT 2>/dev/null || true
        
        # Сохраняем iptables правила
        if command -v iptables-save &> /dev/null; then
            mkdir -p /etc/iptables 2>/dev/null || true
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || \
            iptables-save > /etc/iptables.rules 2>/dev/null || true
        fi
        
        echo "✅ Firewall configured"
        
    else
        echo "❌ Failed to start container"
        exit 1
    fi
    
    # Генерируем SSL сертификат SHA256
    CERT_SHA256=$(echo -n "$SERVER_IP$API_PORT$API_PATH" | openssl dgst -sha256 -binary | openssl enc -base64 | tr -d '\n')
    
    # JSON конфигурация в правильном формате
    JSON_CONFIG="{\"apiUrl\":\"https://$SERVER_IP:$API_PORT/$API_PATH\",\"certSha256\":\"$CERT_SHA256\"}"
    
    # Сохраняем
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
    
    # Управление
    cat > /opt/pulsevpn/manage.sh << 'MANAGEEOF'
#!/bin/bash
case "$1" in
    start)   
        docker start pulsevpn-server && echo "✅ Started" 
        ;;
    stop)    
        docker stop pulsevpn-server && echo "⏹️ Stopped" 
        ;;
    restart) 
        docker restart pulsevpn-server && echo "🔄 Restarted" 
        ;;
    logs)    
        docker logs -f pulsevpn-server 
        ;;
    status)  
        if docker ps | grep -q pulsevpn-server; then
            echo "✅ Running"
            docker ps | grep pulsevpn-server
            echo
            echo "Ports:"
            docker port pulsevpn-server
        else
            echo "❌ Not running"
        fi
        ;;
    json)    
        cat /opt/pulsevpn/config.json 
        ;;
    config)  
        echo "=== Outline Manager JSON ==="
        cat /opt/pulsevpn/config.json
        echo
        echo "=== Shadowsocks Direct ==="
        cat /opt/pulsevpn/shadowsocks.json
        echo
        echo "=== Connection Test ==="
        IPV4=$(curl -4 -s api.ipify.org 2>/dev/null || echo "unknown")
        SS_PORT=$(docker port pulsevpn-server | grep '8388/tcp' | cut -d':' -f2)
        echo "Test connection: telnet $IPV4 $SS_PORT"
        ;;
    test)
        echo "🧪 Testing connection..."
        IPV4=$(curl -4 -s api.ipify.org)
        SS_PORT=$(docker port pulsevpn-server | grep '8388/tcp' | cut -d':' -f2)
        if timeout 5 nc -zv $IPV4 $SS_PORT 2>/dev/null; then
            echo "✅ Port $SS_PORT is accessible from outside"
        else
            echo "❌ Port $SS_PORT is not accessible. Check firewall."
            echo "Try: ufw allow $SS_PORT"
        fi
        ;;
    remove)  
        docker rm -f pulsevpn-server
        rm -rf /opt/pulsevpn
        echo "🗑️ Removed" 
        ;;
    *)       
        echo "Usage: $0 {start|stop|restart|logs|status|json|config|test|remove}" 
        ;;
esac
MANAGEEOF
    chmod +x /opt/pulsevpn/manage.sh
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${GREEN}${BOLD}🎉 PulseVPN Server успешно установлен на ARM64!${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo -e "${BLUE}📋 Outline Manager JSON:${NC}"
    echo -e "${GREEN}$JSON_CONFIG${NC}"
    echo
    echo -e "${BLUE}📱 Shadowsocks настройки:${NC}"
    echo "Сервер: $SERVER_IP"
    echo "Порт: $SHADOWSOCKS_PORT"
    echo "Пароль: $SHADOWSOCKS_PASSWORD"
    echo "Метод: chacha20-ietf-poly1305"
    echo
    echo "📊 Команды:"
    echo "• JSON:        /opt/pulsevpn/manage.sh json"
    echo "• Настройки:   /opt/pulsevpn/manage.sh config"
    echo "• Тест связи:  /opt/pulsevpn/manage.sh test"
    echo "• Статус:      /opt/pulsevpn/manage.sh status"
    echo "• Логи:        /opt/pulsevpn/manage.sh logs"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

else
    # x86_64 код остается без изменений
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
