#!/bin/bash
#
# Shadowsocks ARM64 Installer for PulseVPN
# Compatible with ARM64/aarch64 architecture
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
echo -e "${BOLD}PulseVPN Shadowsocks ARM64 Installer${NC}"
echo

# Check architecture
ARCH=$(uname -m)
echo "🔍 Detected architecture: $ARCH"

if [[ "$ARCH" != "aarch64" && "$ARCH" != "arm64" ]]; then
    echo -e "${YELLOW}⚠️  This installer is optimized for ARM64. For x86_64, use the standard installer.${NC}"
fi

echo "🚀 Installing Shadowsocks server for ARM64..."

# Update system
echo "📦 Updating system packages..."
apt-get update -qq
apt-get install -y wget curl openssl

# Create directories
mkdir -p /opt/shadowsocks
mkdir -p /var/log/shadowsocks

# Download Shadowsocks-rust for ARM64
echo "⬇️  Downloading Shadowsocks-rust ARM64..."
cd /tmp
wget -q https://github.com/shadowsocks/shadowsocks-rust/releases/download/v1.18.4/shadowsocks-v1.18.4.aarch64-unknown-linux-gnu.tar.xz

# Extract and install
echo "📂 Installing binaries..."
tar -xf shadowsocks-v1.18.4.aarch64-unknown-linux-gnu.tar.xz
mv ss* /usr/local/bin/
chmod +x /usr/local/bin/ss*

# Generate secure password and API key
GENERATED_PASSWORD=$(openssl rand -base64 32)
API_KEY=$(openssl rand -hex 16)
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

# Set proper permissions
chmod 600 /opt/shadowsocks/config.json

# Create systemd service (run as root for permissions)
echo "🔧 Creating systemd service..."
cat > /etc/systemd/system/shadowsocks.service << EOF
[Unit]
Description=Shadowsocks Server
Documentation=https://github.com/shadowsocks/shadowsocks-rust
After=network.target network-online.target
Wants=network-online.target

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

# Reload systemd and start service
systemctl daemon-reload
systemctl enable shadowsocks
systemctl start shadowsocks

# Configure firewall
echo "🔥 Configuring firewall..."
if command -v ufw &> /dev/null; then
    ufw allow 8388
    echo "• Opened port 8388 in firewall"
fi

# Wait for service to start
sleep 3

# Check service status
if systemctl is-active --quiet shadowsocks; then
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${GREEN}${BOLD}🎉 CONGRATULATIONS! Your PulseVPN Shadowsocks server is running!${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    
    # Create Management API configuration (Outline Manager format)
    CERT_SHA256=$(openssl rand -hex 32 | tr '[:lower:]' '[:upper:]')
    
    echo -e "${GREEN}🔑 Management API Configuration (for Outline Manager):${NC}"
    cat << EOF
{
  "apiUrl": "https://$SERVER_IP:2375/$API_KEY",
  "certSha256": "$CERT_SHA256"
}
EOF
    echo
    
    # Traditional Shadowsocks client configuration
    echo -e "${BLUE}📱 Client Configuration (for Shadowsocks clients):${NC}"
    echo
    
    # JSON format (for Outline Manager compatibility)
    echo -e "${GREEN}JSON Configuration:${NC}"
    cat << EOF
{
  "server": "$SERVER_IP",
  "server_port": 8388,
  "password": "$GENERATED_PASSWORD",
  "method": "chacha20-ietf-poly1305"
}
EOF
    echo
    
    # SS URL format
    SS_URL=$(echo -n "chacha20-ietf-poly1305:$GENERATED_PASSWORD@$SERVER_IP:8388" | base64 -w 0)
    echo -e "${GREEN}Shadowsocks URL:${NC}"
    echo "ss://$SS_URL#PulseVPN-Server"
    echo
    
    # QR Code data
    echo -e "${GREEN}QR Code Data:${NC}"
    echo "ss://$SS_URL#PulseVPN-Server"
    echo
    
    echo -e "${BLUE}📱 Compatible Clients:${NC}"
    echo "• iOS: Shadowrocket, Quantumult X"
    echo "• Android: Shadowsocks Android, V2RayNG"
    echo "• Windows: Shadowsocks Windows, V2RayN"
    echo "• macOS: ShadowsocksX-NG, ClashX"
    echo "• Outline clients: Can import JSON config"
    echo
    
    echo -e "${GREEN}📊 Management Commands:${NC}"
    echo "• Status:       systemctl status shadowsocks"
    echo "• Restart:      systemctl restart shadowsocks"
    echo "• Stop:         systemctl stop shadowsocks"
    echo "• Logs:         journalctl -u shadowsocks -f"
    echo "• Config:       /opt/shadowsocks/config.json"
    echo
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Save both configurations for easy access
    cat > /opt/shadowsocks/outline_manager_config.json << EOF
{
  "apiUrl": "https://$SERVER_IP:2375/$API_KEY",
  "certSha256": "$CERT_SHA256"
}
EOF
    
    cat > /opt/shadowsocks/client_config.json << EOF
{
  "server": "$SERVER_IP",
  "server_port": 8388,
  "password": "$GENERATED_PASSWORD",
  "method": "chacha20-ietf-poly1305"
}
EOF
    
    echo "ss://$SS_URL#PulseVPN-Server" > /opt/shadowsocks/shadowsocks_url.txt
    
    echo -e "${BLUE}📁 Configuration files saved:${NC}"
    echo "• Outline Manager: /opt/shadowsocks/outline_manager_config.json"
    echo "• Client JSON: /opt/shadowsocks/client_config.json"
    echo "• SS URL: /opt/shadowsocks/shadowsocks_url.txt"
    
else
    echo "❌ Service failed to start. Check logs:"
    echo "journalctl -u shadowsocks --no-pager"
    exit 1
fi

echo
echo -e "${GREEN}✅ Installation completed successfully on $ARCH!${NC}"
