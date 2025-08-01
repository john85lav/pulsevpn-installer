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
    _                   ***    ***  *   * 
   |  * \ *   | |    | |  / || \ | |
   | |) | | | | / |/ * \ | | | |  *  |  \| |
   |  /| || | \ \  / | | | || | |\  |
   ||    \,||_/\| ||  \__|_| \_|
EOF
echo -e "${NC}"
echo -e "${BOLD}Personal VPN Server Installer${NC}"
echo

# Определяем архитектуру
ARCH=$(uname -m)
echo "🔍 Detected architecture: $ARCH"

if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
    echo "🚀 Installing PulseVPN server for ARM64..."
    
    # Устанавливаем Docker если нужно
    if ! command -v docker &> /dev/null; then
        echo "📦 Installing Docker..."
        curl -fsSL https://get.docker.com | sh
        systemctl enable docker
        systemctl start docker
    fi
    
    # Генерируем параметры
    SHADOWSOCKS_PASSWORD=$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-22)
    SHADOWSOCKS_PORT=$((RANDOM % 10000 + 20000))
    API_PORT=$((RANDOM % 10000 + 30000))
    
    # Получаем IP сервера
    SERVER_IP=$(curl -s ifconfig.me || curl -s ipinfo.io/ip || curl -s icanhazip.com)
    
    echo "🔧 Starting Shadowsocks server..."
    
    # Запускаем shadowsocks-libev (поддерживает ARM64)
    docker run -d \
        --name shadowbox \
        --restart unless-stopped \
        -p $SHADOWSOCKS_PORT:8388 \
        -p $API_PORT:8080 \
        shadowsocks/shadowsocks-libev:latest \
        ss-server -s 0.0.0.0 -p 8388 -k "$SHADOWSOCKS_PASSWORD" -m chacha20-ietf-poly1305 -u
    
    # Ждем запуска
    sleep 3
    
    # Создаем простой API сервер для совместимости
    docker run -d \
        --name outline-api \
        --restart unless-stopped \
        -p $API_PORT:3000 \
        -e SHADOWSOCKS_HOST="$SERVER_IP" \
        -e SHADOWSOCKS_PORT="$SHADOWSOCKS_PORT" \
        -e SHADOWSOCKS_PASSWORD="$SHADOWSOCKS_PASSWORD" \
        node:alpine sh -c "
        npm install express cors body-parser &&
        node -e \"
        const express = require('express');
        const app = express();
        app.use(express.json());
        app.use(require('cors')());
        app.get('/server', (req, res) => res.json({
            name: 'PulseVPN-ARM64',
            serverId: 'arm64-server',
            metricsEnabled: false,
            createdTimestampMs: Date.now(),
            version: '1.0.0',
            accessKeyDataLimit: null,
            portForNewAccessKeys: $SHADOWSOCKS_PORT,
            hostnameForAccessKeys: '$SERVER_IP'
        }));
        app.listen(3000, () => console.log('API ready'));
        \"
        "
    
    # Генерируем фиктивный сертификат SHA256 для совместимости
    CERT_SHA256=$(echo -n "$SERVER_IP:$API_PORT" | openssl dgst -sha256 -binary | openssl enc -base64)
    
    # Создаем JSON конфигурацию
    JSON_CONFIG="{\"apiUrl\":\"https://$SERVER_IP:$API_PORT/\",\"certSha256\":\"$CERT_SHA256\"}"
    
    # Сохраняем конфигурацию
    mkdir -p /opt/pulsevpn
    echo "$JSON_CONFIG" > /opt/pulsevpn/config.json
    
    # Переименовываем контейнер для совместимости
    docker rename shadowbox pulsevpn-server 2>/dev/null || true
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${GREEN}${BOLD}🎉 CONGRATULATIONS! Your PulseVPN server is up and running on ARM64.${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo -e "${BLUE}PulseVPN JSON configuration:${NC}"
    echo
    echo -e "${BLUE}$JSON_CONFIG${NC}"
    echo
    echo -e "${GREEN}📱 Alternative configurations:${NC}"
    echo
    echo "• Copy JSON above into Outline Manager"
    echo "• Or use any Shadowsocks client with:"
    echo "  Server: $SERVER_IP"
    echo "  Port: $SHADOWSOCKS_PORT"
    echo "  Password: $SHADOWSOCKS_PASSWORD"
    echo "  Method: chacha20-ietf-poly1305"
    echo
    echo "📊 Management Commands:"
    echo "• View logs:    docker logs -f pulsevpn-server"
    echo "• Restart:      docker restart pulsevpn-server"
    echo "• Stop:         docker stop pulsevpn-server"
    echo
    echo "Configuration saved to /opt/pulsevpn/config.json"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

else
    echo "🚀 Installing PulseVPN server (Outline-based) for x86_64..."
    
    # Временный файл для вывода
    temp_file=$(mktemp)
    
    # Запускаем оригинальный установщик Outline
    if sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/Jigsaw-Code/outline-apps/master/server_manager/install_scripts/install_server.sh)" 2>&1 | tee "$temp_file"; then
        echo
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo -e "${GREEN}${BOLD}🎉 CONGRATULATIONS! Your PulseVPN server is up and running.${NC}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo
        
        # Извлекаем JSON конфигурацию
        json_config=$(grep -o '{"apiUrl":"[^"]","certSha256":"[^"]"}' "$temp_file" | tail -1)
        if [ -n "$json_config" ]; then
            echo -e "${BLUE}PulseVPN JSON configuration:${NC}"
            echo
            echo -e "${BLUE}$json_config${NC}"
            echo
            
            # Извлекаем детали сервера
            api_url=$(echo "$json_config" | grep -o '"apiUrl":"[^"]*"' | cut -d'"' -f4)
            server_ip=$(echo "$api_url" | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+')
            echo -e "${GREEN}📱 Alternative configurations:${NC}"
            echo
            echo "• Copy JSON above into Outline Manager"
            echo "• Or use any Shadowsocks client with server: $server_ip"
            echo
            
            # Переименовываем контейнер
            docker rename shadowbox pulsevpn-server 2>/dev/null || true
            
            # Сохраняем конфигурацию
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
    
    # Очистка
    rm -f "$temp_file"
fi
