#!/bin/bash
#
# PulseVPN Server Installer (Outline-based)
# Usage: curl -sSL https://raw.githubusercontent.com/john85lav/pulsevpn-installer/main/install.sh | sudo bash
#

set -euo pipefail

# Colors for output
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

echo -e "${BLUE}${BOLD}"
cat << 'EOF'
    ____        __           _    ____  _   _ 
   |  _ \ _   _| |___  ___  | |  / ___|| \ | |
   | |_) | | | | / __|/ _ \ | | | |  _  |  \| |
   |  __/| |_| | \__ \  __/ | | | |_| | |\  |
   |_|    \__,_|_|___/\___| |_|  \____|_| \_|
EOF
echo -e "${NC}"
echo -e "${BOLD}Personal VPN Server Installer (Outline-based)${NC}"
echo

echo "🔧 Installing Outline server infrastructure..."

# Run the original Outline installer
temp_output=$(mktemp)
if sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/Jigsaw-Code/outline-apps/master/server_manager/install_scripts/install_server.sh)" > "$temp_output" 2>&1; then
    echo "✅ Outline server installed successfully!"
    
    # Extract the JSON config
    json_config=$(grep -o '{"apiUrl":"[^"]*","certSha256":"[^"]*"}' "$temp_output" || echo "")
    
    if [ -n "$json_config" ]; then
        echo
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo -e "${GREEN}${BOLD}🎉 CONGRATULATIONS! Your PulseVPN server is up and running.${NC}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo
        echo -e "${BLUE}🔧 PulseVPN JSON configuration:${NC}"
        echo
        echo -e "${BLUE}$json_config${NC}"
        echo
        echo -e "${GREEN}✅ Copy the JSON above and paste it into Outline Manager${NC}"
        echo -e "${GREEN}✅ Or use any Shadowsocks client with the server details${NC}"
        echo
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        # Rename container for branding
        docker rename shadowbox pulsevpn-server 2>/dev/null || true
        
        # Save config for later reference
        mkdir -p /opt/pulsevpn
        echo "$json_config" > /opt/pulsevpn/config.json
        cat "$temp_output" > /opt/pulsevpn/install_log.txt
        
        echo "📋 Configuration saved to /opt/pulsevpn/config.json"
        echo "📊 Management commands:"
        echo "• View logs:    docker logs -f pulsevpn-server"
        echo "• Restart:      docker restart pulsevpn-server"
        echo "• Stop:         docker stop pulsevpn-server"
    else
        echo "⚠️  Could not extract JSON config, but server should be working"
        cat "$temp_output"
    fi
else
    echo "❌ Installation failed"
    cat "$temp_output"
    rm -f "$temp_output"
    exit 1
fi

rm -f "$temp_output"
