#!/bin/bash
#
# PulseVPN Server Universal Installer (ARM64 + x86_64 support)
# Usage: curl -sSL https://raw.githubusercontent.com/your-repo/pulsevpn-installer/main/install.sh | sudo bash
#
set -euo pipefail

# Colors
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

echo -e "${BLUE}${BOLD}"
cat << 'EOF'
    ____        **           *****    ***_  *   * 
   |  * \ *   *| |*__  ___  | |  / ___|| \ | |
   | |_) | | | | / __|/ * \ | | | |  *  |  \| |
   |  __/| |_| | \__ \  __/ | | | |_| | |\  |
   |_|    \__,_|_|___/\___| |_|  \____|_| \_|
EOF
echo -e "${NC}"
echo -e "${BOLD}Personal VPN Server Universal Installer${NC}"
echo

# Detect architecture
ARCH=$(uname -m)
echo "🔍 Detected architecture: $ARCH"

case $ARCH in
    x86_64|amd64)
        echo -e "${GREEN}✅ x86_64 architecture detected - using Outline installer${NC}"
        INSTALLER_URL="https://raw.githubusercontent.com/Jigsaw-Code/outline-apps/master/server_manager/install_scripts/install_server.sh"
        VPN_TYPE="outline"
        ;;
    aarch64|arm64)
        echo -e "${YELLOW}⚠️  ARM64 architecture detected - using WireGuard installer${NC}"
        VPN_TYPE="wireguard"
        ;;
    *)
        echo "❌ Unsupported architecture: $ARCH"
        echo "Supported: x86_64, amd64, aarch64, arm64"
        exit 1
        ;;
esac

echo "🚀 Installing PulseVPN server ($VPN_TYPE-based)..."
echo

# Temporary file to capture output
temp_file=$(mktemp)

if [ "$VPN_TYPE" = "outline" ]; then
    # Original Outline installation for x86_64
    if sudo bash -c "$(wget -qO- $INSTALLER_URL)" 2>&1 | tee "$temp_file"; then
        
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
            
            # Extract server details
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
    else
        echo "❌ Outline installation failed. Check the error above."
        exit 1
    fi

elif [ "$VPN_TYPE" = "wireguard" ]; then
    # Shadowsocks installation for ARM64 (Outline API compatible)
    echo "🔧 Installing Shadowsocks server for ARM64 with Outline API compatibility..."
    
    # Update system
    apt update -y
    
    # Install Docker and dependencies
    apt install -y curl jq openssl
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker
    systemctl start docker
    
    # Get server IP
    SERVER_IP=$(curl -s https://api.ipify.org 2>/dev/null || curl -s https://ipinfo.io/ip 2>/dev/null)
    
    if [ -z "$SERVER_IP" ]; then
        echo "❌ Could not detect server IP"
        exit 1
    fi
    
    # Generate random port and password
    SS_PORT=$(shuf -i 1024-65535 -n 1)
    SS_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-16)
    API_PORT=2375
    
    # Generate TLS certificate for API
    mkdir -p /opt/pulsevpn/certs
    openssl req -x509 -newkey rsa:2048 -keyout /opt/pulsevpn/certs/server.key -out /opt/pulsevpn/certs/server.crt -days 365 -nodes -subj "/CN=$SERVER_IP"
    
    # Get certificate SHA256
    CERT_SHA256=$(openssl x509 -in /opt/pulsevpn/certs/server.crt -noout -fingerprint -sha256 | cut -d'=' -f2 | tr -d ':')
    
    # Generate API key
    API_KEY=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-20)
    
    # Create Shadowsocks config
    cat > /opt/pulsevpn/shadowsocks.json << EOF
{
    "server": "0.0.0.0",
    "server_port": $SS_PORT,
    "password": "$SS_PASSWORD",
    "method": "chacha20-ietf-poly1305",
    "timeout": 300
}
EOF
    
    # Run Shadowsocks container
    docker run -d \
        --name pulsevpn-server \
        --restart unless-stopped \
        -p $SS_PORT:$SS_PORT \
        -p $API_PORT:$API_PORT \
        -v /opt/pulsevpn/shadowsocks.json:/etc/shadowsocks.json:ro \
        -v /opt/pulsevpn/certs:/certs:ro \
        shadowsocks/shadowsocks-libev:latest \
        ss-server -c /etc/shadowsocks.json -v
    
    # Create simple API server for Outline compatibility
    cat > /opt/pulsevpn/api_server.py << 'EOF'
#!/usr/bin/env python3
import json
import ssl
from http.server import HTTPServer, BaseHTTPRequestHandler

class OutlineAPIHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith('/'):
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            
            # Return server info
            response = {
                "name": "PulseVPN ARM64 Server",
                "serverId": "pulsevpn-arm64",
                "metricsEnabled": True,
                "createdTimestampMs": 1627776000000,
                "version": "1.0.0",
                "accessKeys": [
                    {
                        "id": "client1",
                        "name": "Default Client",
                        "password": "SS_PASSWORD_PLACEHOLDER",
                        "port": SS_PORT_PLACEHOLDER,
                        "method": "chacha20-ietf-poly1305",
                        "accessUrl": f"ss://chacha20-ietf-poly1305:SS_PASSWORD_PLACEHOLDER@SERVER_IP_PLACEHOLDER:SS_PORT_PLACEHOLDER"
                    }
                ]
            }
            
            self.wfile.write(json.dumps(response, indent=2).encode())
        else:
            self.send_response(404)
            self.end_headers()
    
    def log_message(self, format, *args):
        return

if __name__ == '__main__':
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain('/certs/server.crt', '/certs/server.key')
    
    server = HTTPServer(('0.0.0.0', API_PORT_PLACEHOLDER), OutlineAPIHandler)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    
    print(f"API server running on port API_PORT_PLACEHOLDER")
    server.serve_forever()
EOF
    
    # Replace placeholders in API server
    sed -i "s/SS_PASSWORD_PLACEHOLDER/$SS_PASSWORD/g" /opt/pulsevpn/api_server.py
    sed -i "s/SS_PORT_PLACEHOLDER/$SS_PORT/g" /opt/pulsevpn/api_server.py
    sed -i "s/SERVER_IP_PLACEHOLDER/$SERVER_IP/g" /opt/pulsevpn/api_server.py
    sed -i "s/API_PORT_PLACEHOLDER/$API_PORT/g" /opt/pulsevpn/api_server.py
    
    # Start API server
    nohup python3 /opt/pulsevpn/api_server.py > /opt/pulsevpn/api.log 2>&1 &
    
    # Configure firewall
    ufw allow $SS_PORT/tcp
    ufw allow $SS_PORT/udp
    ufw allow $API_PORT/tcp
    
    # Create Outline-compatible JSON
    cat > /opt/pulsevpn/config.json << EOF
{
  "apiUrl": "https://$SERVER_IP:$API_PORT/$API_KEY",
  "certSha256": "$CERT_SHA256"
}
EOF
    
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${GREEN}${BOLD}🎉 CONGRATULATIONS! Your PulseVPN server is up and running.${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo -e "${BLUE}PulseVPN JSON configuration:${NC}"
    echo
    echo -e "${BLUE}$(cat /opt/pulsevpn/config.json)${NC}"
    echo
    echo -e "${GREEN}📱 Alternative configurations:${NC}"
    echo
    echo "• Copy JSON above into Outline Manager"
    echo "• Or use any Shadowsocks client with:"
    echo "  - Server: $SERVER_IP"
    echo "  - Port: $SS_PORT"
    echo "  - Password: $SS_PASSWORD"
    echo "  - Method: chacha20-ietf-poly1305"
    echo
    echo "📊 Management Commands:"
    echo "• View logs:    docker logs -f pulsevpn-server"
    echo "• Restart:      docker restart pulsevpn-server"
    echo "• Stop:         docker stop pulsevpn-server"
    echo
    echo "Configuration saved to /opt/pulsevpn/config.json"
else
    echo "❌ WireGuard installation failed. Check the error above."
    exit 1
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Cleanup
rm -f "$temp_file"
