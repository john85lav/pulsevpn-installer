#!/bin/bash
#
# PulseVPN Server One-Line Installer
# Usage: curl -sSL https://raw.githubusercontent.com/john85lav/pulsevpn-installer/main/install.sh | sudo bash
#
set -euo pipefail

# Colors
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[0;33m'
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
echo -e "${BOLD}Personal VPN Server Installer${NC}"
echo

# Detect architecture
ARCH=$(uname -m)
echo "🔍 Detected architecture: $ARCH"

# x86_64 - use original Outline installer
if [ "$ARCH" = "x86_64" ]; then
    echo "🚀 Installing PulseVPN server (Outline-based)..."
    
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
        
        # Cleanup
        rm -f "$temp_file"
        exit 0
    else
        echo "❌ Installation failed. Check the error above."
        rm -f "$temp_file"
        exit 1
    fi

# ARM64 - custom installation
elif [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
    echo "🚀 Installing PulseVPN server for ARM64..."
    echo -e "${YELLOW}Note: Using Shadowsocks-rust with Management API for ARM64${NC}"
    
    # Update system
    echo "📦 Updating system packages..."
    apt-get update -qq
    apt-get install -y wget curl openssl
    
    # Create directories
    mkdir -p /opt/shadowsocks
    mkdir -p /opt/pulsevpn-api
    
    # Download Shadowsocks-rust for ARM64
    echo "⬇️  Downloading Shadowsocks-rust ARM64..."
    cd /tmp
    wget -q https://github.com/shadowsocks/shadowsocks-rust/releases/download/v1.18.4/shadowsocks-v1.18.4.aarch64-unknown-linux-gnu.tar.xz
    tar -xf shadowsocks-v1.18.4.aarch64-unknown-linux-gnu.tar.xz
    mv ss* /usr/local/bin/
    chmod +x /usr/local/bin/ss*
    
    # Generate secure credentials
    GENERATED_PASSWORD=$(openssl rand -base64 32)
    API_KEY=$(openssl rand -hex 16)
    CERT_SHA256=$(openssl rand -hex 32 | tr '[:lower:]' '[:upper:]')
    SERVER_IP=$(curl -4 -s ifconfig.me || curl -4 -s ipinfo.io/ip || echo "YOUR_SERVER_IP")
    
    # Create Shadowsocks configuration
    echo "⚙️  Creating server configuration..."
    cat > /opt/shadowsocks/config.json << EOF
{
    "server": "0.0.0.0",
    "server_port": 8388,
    "password": "$GENERATED_PASSWORD",
    "timeout": 300,
    "method": "chacha20-ietf-poly1305",
    "fast_open": false,
    "no_delay": true,
    "reuse_port": true,
    "workers": 1
}
EOF
    
    chmod 644 /opt/shadowsocks/config.json
    
    # Create Shadowsocks systemd service
    echo "🔧 Creating Shadowsocks service..."
    cat > /etc/systemd/system/shadowsocks.service << EOF
[Unit]
Description=Shadowsocks Server
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/ssserver -c /opt/shadowsocks/config.json
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    
    # Create Management API server
    echo "🔧 Creating PulseVPN Management API..."
    cat > /opt/pulsevpn-api/management_server.py << 'EOF'
#!/usr/bin/env python3
import json
import subprocess
from http.server import HTTPServer, BaseHTTPRequestHandler
from datetime import datetime

class PulseVPNManagementAPI(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith('/access-keys'):
            self.handle_access_keys()
        elif '/server' in self.path:
            self.handle_server_info()
        else:
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(b'{"status": "PulseVPN Management API"}')
    
    def handle_access_keys(self):
        try:
            with open('/opt/shadowsocks/config.json', 'r') as f:
                config = json.load(f)
            
            keys = [{
                "id": "pulsevpn-default",
                "name": "PulseVPN Default Key", 
                "password": config["password"],
                "port": config["server_port"],
                "method": config["method"]
            }]
            
            self.send_json_response({"accessKeys": keys})
        except Exception as e:
            self.send_error(500, str(e))
    
    def handle_server_info(self):
        server_info = {
            "name": "PulseVPN ARM64 Server",
            "serverId": "pulsevpn-arm64-server", 
            "version": "1.0.0-arm64"
        }
        self.send_json_response(server_info)
    
    def send_json_response(self, data):
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(json.dumps(data, indent=2).encode())

if __name__ == '__main__':
    server = HTTPServer(('0.0.0.0', 2375), PulseVPNManagementAPI)
    print("Starting PulseVPN Management API on port 2375...")
    server.serve_forever()
EOF
    
    chmod +x /opt/pulsevpn-api/management_server.py
    
    # Create Management API systemd service
    cat > /etc/systemd/system/pulsevpn-api.service << EOF
[Unit]
Description=PulseVPN Management API
After=network.target shadowsocks.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/pulsevpn-api
ExecStart=/usr/bin/python3 /opt/pulsevpn-api/management_server.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    
    # Start services
    systemctl daemon-reload
    systemctl enable shadowsocks pulsevpn-api
    systemctl start shadowsocks pulsevpn-api
    
    # Configure firewall
    echo "🔥 Configuring firewall..."
    if command -v ufw &> /dev/null; then
        ufw allow 8388
        ufw allow 2375
        echo "• Opened ports 8388 and 2375"
    fi
    
    # Wait for services to start
    sleep 5
    
    # Check if services are running
    if systemctl is-active --quiet shadowsocks && systemctl is-active --quiet pulsevpn-api; then
        echo
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo -e "${GREEN}${BOLD}🎉 CONGRATULATIONS! Your PulseVPN server is up and running.${NC}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo
        
        echo -e "${BLUE}PulseVPN JSON configuration:${NC}"
        echo
        echo -e "${BLUE}{"
        echo "  \"apiUrl\": \"https://$SERVER_IP:2375/$API_KEY\","
        echo "  \"certSha256\": \"$CERT_SHA256\""
        echo "}${NC}"
        echo
        
        echo -e "${GREEN}📱 Alternative configurations:${NC}"
        echo
        echo "• Copy JSON above into PulseVPN Manager"
        echo "• Or use any Shadowsocks client with server: $SERVER_IP"
        echo
        
        # Save configs
        mkdir -p /opt/pulsevpn
        cat > /opt/pulsevpn/config.json << EOF
{
  "apiUrl": "https://$SERVER_IP:2375/$API_KEY",
  "certSha256": "$CERT_SHA256"
}
EOF
        
        cat > /opt/pulsevpn/client_config.json << EOF
{
  "server": "$SERVER_IP",
  "server_port": 8388,
  "password": "$GENERATED_PASSWORD",
  "method": "chacha20-ietf-poly1305"
}
EOF
        
        echo "📊 Management Commands:"
        echo "• View Shadowsocks logs: journalctl -u shadowsocks -f"
        echo "• View API logs:         journalctl -u pulsevpn-api -f"
        echo "• Restart Shadowsocks:   systemctl restart shadowsocks"
        echo "• Restart API:           systemctl restart pulsevpn-api"
        echo "• Test API:              curl http://localhost:2375/server"
        echo
        echo "Configuration saved to /opt/pulsevpn/config.json"
        echo "Client config saved to /opt/pulsevpn/client_config.json"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
    else
        echo "❌ Services failed to start. Check logs:"
        echo "• Shadowsocks: journalctl -u shadowsocks --no-pager"
        echo "• API:         journalctl -u pulsevpn-api --no-pager"
        exit 1
    fi

# Unsupported architecture
else
    echo "❌ Unsupported machine type: $ARCH. Please run this script on a x86_64 or aarch64 machine"
    echo
    echo "Sorry! Something went wrong. If you can't figure this out, please copy and paste all this output into the PulseVPN Manager screen, and send it to us, to see if we can help you."
    exit 1
fi
