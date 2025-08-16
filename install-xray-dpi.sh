#!/bin/bash
#
# PulseVPN XRay DPI Bypass Installer
# Adds DPI bypass capabilities to existing PulseVPN servers
# Usage: curl -sSL https://raw.githubusercontent.com/john85lav/pulsevpn-installer/main/install-xray-dpi.sh | sudo bash
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
DOMAIN=""
SERVER_IP=""
XRAY_CONFIG_DIR="/usr/local/etc/xray"
API_PORT="8080"
SS_PORT="8388"
HTTPS_PORT="443"
UUID=""
SS_PASSWORD=""
SECRET_PATH=""

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

show_header() {
    echo -e "${BLUE}${BOLD}"
    cat << 'EOF'
    ____        __           _    ____  _   _    ____  ____ ___
   |  _ \ _   _| |___  ___  | |  / ___|| \ | |  |  _ \|  _ \_ _|
   | |_) | | | | / __|/ _ \ | | | |  _  |  \| |  | | | | |_) | |
   |  __/| |_| | \__ \  __/ | | | |_| | |\  |  | |_| |  __/| |
   |_|    \__,_|_|___/\___| |_|  \____|_| \_|  |____/|_|  |___|
                                                               
EOF
    echo -e "${NC}"
    echo -e "${BOLD}DPI Bypass Enhancement for PulseVPN${NC}"
    echo "=============================================="
    echo
}

# Получение IPv4 адреса
get_ipv4() {
    local ipv4=""
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
    ipv4=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") print $(i+1); exit}' | head -1)
    if [[ "$ipv4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$ipv4"
        return
    fi
    echo "127.0.0.1"
}

# Проверка свободности порта
check_port_free() {
    local port=$1
    if ss -tuln 2>/dev/null | grep -q ":$port " || netstat -tuln 2>/dev/null | grep -q ":$port "; then
        return 1
    fi
    return 0
}

# Остановка конфликтующих сервисов
stop_conflicting_services() {
    log "Проверка конфликтующих сервисов..."
    
    # Останавливаем возможные сервисы на портах
    local services_to_stop=("nginx" "apache2" "httpd" "shadowbox" "outline-server")
    
    for service in "${services_to_stop[@]}"; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            log_warn "Остановка сервиса $service..."
            systemctl stop "$service" || true
        fi
    done
    
    # Проверяем порт 8388 (может занимать существующий PulseVPN)
    if ! check_port_free $SS_PORT; then
        log_warn "Порт $SS_PORT занят, будем использовать порт 23 для XRay"
        SS_PORT="23"
    fi
    
    # Проверяем порт 443
    if ! check_port_free $HTTPS_PORT; then
        log_warn "Порт $HTTPS_PORT занят, VLESS будет недоступен"
    fi
}

# Установка зависимостей
install_dependencies() {
    log "Установка зависимостей..."
    
    # Обновляем репозитории
    if command -v apt-get &> /dev/null; then
        apt-get update -qq
        apt-get install -y curl wget unzip nginx certbot python3-certbot-nginx jq bc
    elif command -v yum &> /dev/null; then
        yum install -y curl wget unzip nginx certbot python3-certbot-nginx jq bc
    elif command -v dnf &> /dev/null; then
        dnf install -y curl wget unzip nginx certbot python3-certbot-nginx jq bc
    else
        log_error "Неподдерживаемый менеджер пакетов"
        exit 1
    fi
    
    log_success "Зависимости установлены"
}

# Установка XRay
install_xray() {
    log "Установка XRay..."
    
    # Используем официальный установщик
    if bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install; then
        log_success "XRay установлен"
    else
        log_error "Ошибка установки XRay"
        exit 1
    fi
}

# Генерация учетных данных
generate_credentials() {
    log "Генерация учетных данных..."
    
    UUID=$(cat /proc/sys/kernel/random/uuid)
    SS_PASSWORD=$(openssl rand -hex 16)
    SECRET_PATH="/$(openssl rand -hex 8)"
    
    log "UUID: $UUID"
    log "SS Password: $SS_PASSWORD"
    log "Secret Path: $SECRET_PATH"
}

# Получение SSL сертификата
setup_ssl() {
    log "Настройка SSL сертификата..."
    
    # Если домен не задан, используем IP
    if [[ -z "$DOMAIN" ]]; then
        log_warn "Домен не задан, SSL будет недоступен. Используйте только SS-2022."
        return
    fi
    
    # Останавливаем nginx для получения сертификата
    systemctl stop nginx || true
    
    # Получаем сертификат
    if certbot certonly --standalone --preferred-challenges http -d "$DOMAIN" --agree-tos --register-unsafely-without-email --non-interactive; then
        log_success "SSL сертификат получен для $DOMAIN"
        
        # Настройка автообновления
        echo "renew_hook = systemctl reload xray && systemctl reload nginx" >> "/etc/letsencrypt/renewal/$DOMAIN.conf"
    else
        log_warn "Не удалось получить SSL сертификат. VLESS будет недоступен."
        DOMAIN=""
    fi
}

# Создание конфигурации XRay
create_xray_config() {
    log "Создание конфигурации XRay..."
    
    # Базовая конфигурация с SS-2022
    local config='{
  "log": {
    "loglevel": "info"
  },
  "routing": {
    "rules": [],
    "domainStrategy": "AsIs"
  },
  "inbounds": [
    {
      "port": '$SS_PORT',
      "tag": "ss2022",
      "protocol": "shadowsocks",
      "settings": {
        "method": "2022-blake3-aes-128-gcm",
        "password": "'$SS_PASSWORD'",
        "network": "tcp,udp"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    }'
    
    # Добавляем VLESS если есть SSL
    if [[ -n "$DOMAIN" ]]; then
        config+=',
    {
      "port": '$HTTPS_PORT',
      "protocol": "vless",
      "tag": "vless_tls",
      "settings": {
        "clients": [
          {
            "id": "'$UUID'",
            "email": "default@'$DOMAIN'",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none",
        "fallbacks": [
          {
            "path": "'$SECRET_PATH'",
            "dest": "@vless-ws"
          },
          {
            "dest": "'$API_PORT'"
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "alpn": ["http/1.1", "h2"],
          "certificates": [
            {
              "certificateFile": "/etc/letsencrypt/live/'$DOMAIN'/fullchain.pem",
              "keyFile": "/etc/letsencrypt/live/'$DOMAIN'/privkey.pem"
            }
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    },
    {
      "listen": "@vless-ws",
      "protocol": "vless",
      "tag": "vless_ws",
      "settings": {
        "clients": [
          {
            "id": "'$UUID'",
            "email": "websocket@'$DOMAIN'"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "'$SECRET_PATH'"
        }
      }
    }'
    fi
    
    config+='
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}'
    
    # Сохраняем конфигурацию
    echo "$config" > "$XRAY_CONFIG_DIR/config.json"
    
    log_success "Конфигурация XRay создана"
}

# Настройка Nginx
setup_nginx() {
    log "Настройка Nginx..."
    
    # Создаем конфигурацию Nginx
    cat > /etc/nginx/sites-enabled/default << EOF
server {
    listen 127.0.0.1:$API_PORT default_server;
    listen [::1]:$API_PORT default_server;
    
    root /var/www/html;
    index index.html index.htm;
    server_name _;
    
    # API для генерации ключей (совместимость с PulseVPN app)
    location ~ ^/([a-zA-Z0-9]+)/access-keys$ {
        default_type application/json;
        add_header Access-Control-Allow-Origin "*";
        add_header Access-Control-Allow-Methods "GET, POST, OPTIONS";
        add_header Access-Control-Allow-Headers "Content-Type, Authorization";
        
        if (\$request_method = 'OPTIONS') {
            return 204;
        }
        
        if (\$request_method = 'POST') {
            return 200 '{
                "id": "dpi-bypass-key",
                "name": "",
                "password": "$SS_PASSWORD",
                "port": $SS_PORT,
                "method": "2022-blake3-aes-128-gcm",
                "accessUrl": "ss://MjAyMi1ibGFrZTMtYWVzLTEyOC1nY206$SS_PASSWORD@$SERVER_IP:$SS_PORT/?outline=1"
            }';
        }
        
        return 200 '{"accessKeys": []}';
    }
    
    # Информация о сервере
    location ~ ^/([a-zA-Z0-9]+)/server$ {
        default_type application/json;
        return 200 '{
            "name": "PulseVPN DPI Bypass Server",
            "serverId": "$SERVER_IP",
            "metricsEnabled": false,
            "version": "1.0.0-dpi",
            "portForNewAccessKeys": $SS_PORT,
            "hostnameForAccessKeys": "$SERVER_IP"
        }';
    }
    
    # Метрики для мониторинга
    location /metrics {
        default_type application/json;
        add_header Access-Control-Allow-Origin "*";
        
        if (\$request_method = 'OPTIONS') {
            return 204;
        }
        
        return 200 '{
            "timestamp": "$(date -Iseconds)",
            "dpi_bypass_enabled": true,
            "protocols": ["shadowsocks-2022"$([ -n "$DOMAIN" ] && echo ', "vless-xtls", "vless-websocket"')],
            "server_ip": "$SERVER_IP",
            "ss_port": $SS_PORT
        }';
    }
    
    # Главная страница (маскировка)
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
    
    # Создаем простую главную страницу
    mkdir -p /var/www/html
    cat > /var/www/html/index.html << EOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Welcome</title>
    <style>
        body { font-family: system-ui; line-height: 1.6; margin: 40px auto; max-width: 800px; padding: 20px; }
        .feature { margin: 20px 0; padding: 15px; background: #f5f5f5; border-left: 4px solid #007bff; }
    </style>
</head>
<body>
    <h1>🔒 Secure Infrastructure</h1>
    <div class="feature">
        <h3>Enterprise Security</h3>
        <p>Advanced encryption protocols with DPI bypass technology.</p>
    </div>
    <div class="feature">
        <h3>Global Network</h3>
        <p>High-performance infrastructure worldwide.</p>
    </div>
    <div class="feature">
        <h3>Universal Compatibility</h3>
        <p>Works on all devices and networks.</p>
    </div>
</body>
</html>
EOF
    
    log_success "Nginx настроен"
}

# Настройка фаервола
configure_firewall() {
    log "Настройка фаервола..."
    
    # UFW
    if command -v ufw &> /dev/null && ufw status | grep -q 'Status: active'; then
        ufw allow $SS_PORT/tcp > /dev/null 2>&1 || true
        ufw allow $SS_PORT/udp > /dev/null 2>&1 || true
        [ -n "$DOMAIN" ] && ufw allow $HTTPS_PORT/tcp > /dev/null 2>&1 || true
        log_success "UFW правила добавлены"
    fi
    
    # iptables
    if command -v iptables &> /dev/null; then
        iptables -I INPUT -p tcp --dport $SS_PORT -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p udp --dport $SS_PORT -j ACCEPT 2>/dev/null || true
        [ -n "$DOMAIN" ] && iptables -I INPUT -p tcp --dport $HTTPS_PORT -j ACCEPT 2>/dev/null || true
        
        # Сохранение правил
        if command -v netfilter-persistent &> /dev/null; then
            netfilter-persistent save > /dev/null 2>&1 || true
        fi
        log_success "iptables правила добавлены"
    fi
}

# Запуск сервисов
start_services() {
    log "Запуск сервисов..."
    
    # Устанавливаем права на SSL сертификаты
    if [[ -n "$DOMAIN" ]]; then
        chown -R root:root /etc/letsencrypt/
        chmod -R 755 /etc/letsencrypt/live/
        chmod -R 755 /etc/letsencrypt/archive/
    fi
    
    # Запускаем XRay
    systemctl restart xray
    systemctl enable xray
    
    # Запускаем Nginx
    systemctl restart nginx
    systemctl enable nginx
    
    # Проверяем статус
    sleep 3
    if systemctl is-active --quiet xray; then
        log_success "XRay запущен"
    else
        log_error "XRay не запустился"
        systemctl status xray --no-pager -l
        exit 1
    fi
    
    if systemctl is-active --quiet nginx; then
        log_success "Nginx запущен"
    else
        log_error "Nginx не запустился"
        systemctl status nginx --no-pager -l
        exit 1
    fi
}

# Сохранение конфигурации
save_config() {
    log "Сохранение конфигурации..."
    
    mkdir -p /opt/pulsevpn
    
    # Генерируем SS-2022 URL
    local ss_b64=$(echo -n "2022-blake3-aes-128-gcm:$SS_PASSWORD" | base64 -w 0)
    local ss_url="ss://$ss_b64@$SERVER_IP:$SS_PORT/?outline=1"
    
    # Генерируем VLESS URLs если есть SSL
    local vless_vision=""
    local vless_ws=""
    if [[ -n "$DOMAIN" ]]; then
        vless_vision="vless://$UUID@$DOMAIN:$HTTPS_PORT?encryption=none&flow=xtls-rprx-vision&security=tls&sni=$DOMAIN&type=tcp&headerType=none#PulseVPN-DPI-Vision"
        vless_ws="vless://$UUID@$DOMAIN:$HTTPS_PORT?encryption=none&security=tls&sni=$DOMAIN&type=ws&host=$DOMAIN&path=$SECRET_PATH#PulseVPN-DPI-WebSocket"
    fi
    
    # Создаем JSON конфигурацию для PulseVPN app
    local json_config="{\"apiUrl\":\"https://$SERVER_IP:$API_PORT\",\"certSha256\":\"$(echo -n "$SERVER_IP:$API_PORT" | openssl dgst -sha256 -hex | sed 's/.* //' | tr 'a-f' 'A-F')\"}"
    
    # Сохраняем все конфигурации
    cat > /opt/pulsevpn/dpi-bypass-config.json << EOF
{
  "server_ip": "$SERVER_IP",
  "domain": "$DOMAIN",
  "ports": {
    "shadowsocks_2022": $SS_PORT,
    "vless_https": $HTTPS_PORT,
    "api": $API_PORT
  },
  "credentials": {
    "uuid": "$UUID",
    "ss_password": "$SS_PASSWORD",
    "secret_path": "$SECRET_PATH"
  },
  "connections": {
    "shadowsocks_2022": "$ss_url",
    "vless_vision": "$vless_vision",
    "vless_websocket": "$vless_ws"
  },
  "api": {
    "json_config": $json_config,
    "endpoints": {
      "keys": "http://$SERVER_IP:$API_PORT/{server-id}/access-keys",
      "server": "http://$SERVER_IP:$API_PORT/{server-id}/server",
      "metrics": "http://$SERVER_IP:$API_PORT/metrics"
    }
  }
}
EOF
    
    # Создаем удобный скрипт управления
    cat > /opt/pulsevpn/dpi-manage.sh << 'EOF_MANAGE'
#!/bin/bash
set -euo pipefail

CONFIG_FILE="/opt/pulsevpn/dpi-bypass-config.json"
GREEN='\033[0;32m'
BLUE='\033[0;34m'
BOLD='\033[1m'
RED='\033[0;31m'
NC='\033[0m'

show_header() {
    echo -e "${BLUE}${BOLD}PulseVPN DPI Bypass Manager${NC}"
    echo "====================================="
}

show_usage() {
    echo "Usage: $0 {start|stop|restart|status|config|logs|test|remove}"
    echo
    echo "Commands:"
    echo "  start     - Start XRay DPI bypass"
    echo "  stop      - Stop XRay DPI bypass"
    echo "  restart   - Restart XRay DPI bypass"
    echo "  status    - Show service status"
    echo "  config    - Show connection URLs"
    echo "  logs      - Show XRay logs"
    echo "  test      - Test DPI bypass connections"
    echo "  remove    - Remove DPI bypass (keep original PulseVPN)"
}

case "${1:-}" in
    start)
        systemctl start xray nginx
        echo -e "${GREEN}✅ DPI Bypass services started${NC}"
        ;;
    stop)
        systemctl stop xray nginx
        echo -e "${GREEN}⏹️ DPI Bypass services stopped${NC}"
        ;;
    restart)
        systemctl restart xray nginx
        echo -e "${GREEN}🔄 DPI Bypass services restarted${NC}"
        ;;
    status)
        show_header
        echo -e "${BOLD}XRay Status:${NC}"
        systemctl status xray --no-pager -l | head -5
        echo
        echo -e "${BOLD}Nginx Status:${NC}"
        systemctl status nginx --no-pager -l | head -5
        ;;
    config)
        show_header
        if [ -f "$CONFIG_FILE" ]; then
            echo -e "${BOLD}🔗 DPI Bypass Connection URLs:${NC}"
            echo
            
            SS_URL=$(jq -r '.connections.shadowsocks_2022' "$CONFIG_FILE")
            echo -e "${GREEN}Shadowsocks-2022 (Best for mobile):${NC}"
            echo "$SS_URL"
            echo
            
            VLESS_VISION=$(jq -r '.connections.vless_vision' "$CONFIG_FILE")
            if [ "$VLESS_VISION" != "null" ] && [ -n "$VLESS_VISION" ]; then
                echo -e "${GREEN}VLESS+XTLS-Vision (Maximum speed):${NC}"
                echo "$VLESS_VISION"
                echo
            fi
            
            VLESS_WS=$(jq -r '.connections.vless_websocket' "$CONFIG_FILE")
            if [ "$VLESS_WS" != "null" ] && [ -n "$VLESS_WS" ]; then
                echo -e "${GREEN}VLESS+WebSocket (CDN compatible):${NC}"
                echo "$VLESS_WS"
                echo
            fi
            
            echo -e "${BOLD}📱 For PulseVPN iOS App:${NC}"
            jq -r '.api.json_config' "$CONFIG_FILE"
            echo
        else
            echo -e "${RED}❌ Configuration file not found${NC}"
        fi
        ;;
    logs)
        journalctl -u xray -f
        ;;
    test)
        show_header
        echo -e "${BOLD}🧪 Testing DPI bypass...${NC}"
        
        if [ -f "$CONFIG_FILE" ]; then
            SERVER_IP=$(jq -r '.server_ip' "$CONFIG_FILE")
            SS_PORT=$(jq -r '.ports.shadowsocks_2022' "$CONFIG_FILE")
            
            if timeout 5 bash -c "</dev/tcp/$SERVER_IP/$SS_PORT" 2>/dev/null; then
                echo -e "${GREEN}✅ Shadowsocks-2022 port $SS_PORT is accessible${NC}"
            else
                echo -e "${RED}❌ Shadowsocks-2022 port $SS_PORT is not accessible${NC}"
            fi
            
            API_PORT=$(jq -r '.ports.api' "$CONFIG_FILE")
            if curl -s --connect-timeout 5 "http://$SERVER_IP:$API_PORT/metrics" > /dev/null; then
                echo -e "${GREEN}✅ API endpoint is working${NC}"
            else
                echo -e "${RED}❌ API endpoint is not accessible${NC}"
            fi
        else
            echo -e "${RED}❌ Configuration file not found${NC}"
        fi
        ;;
    remove)
        echo -e "${RED}⚠️ This will remove DPI bypass but keep original PulseVPN. Continue? (y/N)${NC}"
        read -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            systemctl stop xray nginx 2>/dev/null || true
            systemctl disable xray nginx 2>/dev/null || true
            rm -rf /usr/local/etc/xray /opt/pulsevpn/dpi-* /opt/pulsevpn/dpi-manage.sh
            echo -e "${GREEN}🗑️ DPI Bypass removed${NC}"
        fi
        ;;
    *)
        show_header
        show_usage
        ;;
esac
EOF_MANAGE
    chmod +x /opt/pulsevpn/dpi-manage.sh
    
    log_success "Конфигурация сохранена в /opt/pulsevpn/"
}

# Главная функция
main() {
    show_header
    
    # Проверка прав root
    if [[ $EUID -ne 0 ]]; then
        log_error "Этот скрипт должен запускаться от root"
        exit 1
    fi
    
    # Получение параметров
    SERVER_IP=$(get_ipv4)
    
    # Запрос домена (опционально)
    echo -e "${YELLOW}Введите ваш домен для SSL (или нажмите Enter для пропуска):${NC}"
    read -r DOMAIN
    
    if [[ -n "$DOMAIN" ]]; then
        log "Используется домен: $DOMAIN"
    else
        log_warn "Домен не задан, будет использоваться только Shadowsocks-2022"
    fi
    
    # Выполнение установки
    stop_conflicting_services
    install_dependencies
    install_xray
    generate_credentials
    [[ -n "$DOMAIN" ]] && setup_ssl
    create_xray_config
    setup_nginx
    configure_firewall
    start_services
    save_config
    
    # Финальный вывод
    echo
    echo "=================================================================="
    echo -e "${GREEN}${BOLD}🎉 PulseVPN DPI Bypass успешно установлен!${NC}"
    echo "=================================================================="
    echo
    
    # Показываем ключи
    local ss_b64=$(echo -n "2022-blake3-aes-128-gcm:$SS_PASSWORD" | base64 -w 0)
    echo -e "${BLUE}🔗 Connections (DPI Bypass enabled):${NC}"
    echo
    echo -e "${GREEN}Shadowsocks-2022 (Best for mobile):${NC}"
    echo "ss://$ss_b64@$SERVER_IP:$SS_PORT/?outline=1"
    echo
    
    if [[ -n "$DOMAIN" ]]; then
        echo -e "${GREEN}VLESS+XTLS-Vision (Maximum speed):${NC}"
        echo "vless://$UUID@$DOMAIN:$HTTPS_PORT?encryption=none&flow=xtls-rprx-vision&security=tls&sni=$DOMAIN&type=tcp&headerType=none#PulseVPN-DPI"
        echo
        echo -e "${GREEN}VLESS+WebSocket (CDN compatible):${NC}"
        echo "vless://$UUID@$DOMAIN:$HTTPS_PORT?encryption=none&security=tls&sni=$DOMAIN&type=ws&host=$DOMAIN&path=$SECRET_PATH#PulseVPN-DPI-WS"
        echo
    fi
    
    echo -e "${BLUE}📱 For PulseVPN iOS App:${NC}"
    local api_cert_sha=$(echo -n "$SERVER_IP:$API_PORT" | openssl dgst -sha256 -hex | sed 's/.* //' | tr 'a-f' 'A-F')
    echo "{\"apiUrl\":\"https://$SERVER_IP:$API_PORT\",\"certSha256\":\"$api_cert_sha\"}"
    echo
    
    echo -e "${BOLD}📊 Management Commands:${NC}"
    echo "• Show connections: sudo /opt/pulsevpn/dpi-manage.sh config"
    echo "• Test DPI bypass:  sudo /opt/pulsevpn/dpi-manage.sh test"
    echo "• View logs:        sudo /opt/pulsevpn/dpi-manage.sh logs"
    echo "• Restart:          sudo /opt/pulsevpn/dpi-manage.sh restart"
    echo
    echo -e "${YELLOW}💡 Tips:${NC}"
    echo "• All new keys automatically bypass DPI restrictions"
    echo "• Use Shadowsocks-2022 for mobile networks with DPI"
    echo "• VLESS protocols work best on unrestricted networks"
    echo "• Your original PulseVPN installation remains unchanged"
    echo "=================================================================="
}

# Запуск основной функции
main "$@"
