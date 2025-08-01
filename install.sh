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
    # WireGuard installation for ARM64
    echo "🔧 Installing WireGuard for ARM64..."
    
    # Update system
    apt update -y
    
    # Install WireGuard and dependencies
    apt install -y wireguard qrencode ufw curl jq
    
    # Generate server keys
    SERVER_PRIVATE_KEY=$(wg genkey)
    SERVER_PUBLIC_KEY=$(echo "$SERVER_PRIVATE_KEY" | wg pubkey)
    
    # Get server IP
    SERVER_IP=$(curl -s https://api.ipify.org 2>/dev/null || curl -s https://ipinfo.io/ip 2>/dev/null || echo "YOUR_SERVER_IP")
    
    # Create server config
    cat > /etc/wireguard/wg0.conf << EOF
[Interface]
PrivateKey = $SERVER_PRIVATE_KEY
Address = 10.8.0.1/24
ListenPort = 51820
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o eth+ -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o eth+ -j MASQUERADE

EOF

    # Enable IP forwarding
    echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
    sysctl -p
    
    # Configure firewall
    ufw allow 51820/udp
    
    # Enable and start WireGuard
    systemctl enable wg-quick@wg0
    systemctl start wg-quick@wg0
    
    # Generate first client config
    CLIENT_PRIVATE_KEY=$(wg genkey)
    CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVATE_KEY" | wg pubkey)
    
    # Add client to server config
    cat >> /etc/wireguard/wg0.conf << EOF

[Peer]
PublicKey = $CLIENT_PUBLIC_KEY
AllowedIPs = 10.8.0.2/32
EOF
    
    # Restart WireGuard
    systemctl restart wg-quick@wg0
    
    # Create client config
    mkdir -p /opt/pulsevpn
    cat > /opt/pulsevpn/client1.conf << EOF
[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = 10.8.0.2/24
DNS = 1.1.1.1, 8.8.8.8

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
Endpoint = $SERVER_IP:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
    
    # Generate QR code
    qrencode -t ansiutf8 < /opt/pulsevpn/client1.conf > /opt/pulsevpn/client1_qr.txt
    
    # Create JSON-like config for compatibility
    cat > /opt/pulsevpn/config.json << EOF
{
  "type": "wireguard",
  "server_ip": "$SERVER_IP",
  "server_port": "51820",
  "server_public_key": "$SERVER_PUBLIC_KEY",
  "client_config": "/opt/pulsevpn/client1.conf",
  "management": "systemctl restart wg-quick@wg0"
}
EOF
    
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${GREEN}${BOLD}🎉 CONGRATULATIONS! Your PulseVPN (WireGuard) server is up and running.${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo -e "${BLUE}🔑 WireGuard Client Configuration:${NC}"
    echo
    cat /opt/pulsevpn/client1.conf
    echo
    echo -e "${GREEN}📱 QR Code for mobile:${NC}"
    echo
    cat /opt/pulsevpn/client1_qr.txt
    echo
    echo -e "${GREEN}📊 Management Commands:${NC}"
    echo "• Status:       systemctl status wg-quick@wg0"
    echo "• Restart:      systemctl restart wg-quick@wg0"
    echo "• Stop:         systemctl stop wg-quick@wg0"
    echo "• Add client:   wg set wg0 peer <client_public_key> allowed-ips 10.8.0.X/32"
    echo
    echo "• Client config: /opt/pulsevpn/client1.conf"
    echo "• Server config: /etc/wireguard/wg0.conf"
    echo "• JSON config:   /opt/pulsevpn/config.json"
    echo
else
    echo "❌ WireGuard installation failed. Check the error above."
    exit 1
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Cleanup
rm -f "$temp_file"
