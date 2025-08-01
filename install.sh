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
    json_config=$(grep -o '{"apiUrl":"[^"]","certSha256":"[^"]"}' "$temp_file" | tail -1)

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
else
    echo "❌ Installation failed. Check the error above."
    exit 1
fi
# Cleanup
rm -f "$temp_file"но мне надо и для ARM64 . Пример-{
  "apiUrl": "https://89.46.131.67:2375/PUAnw2TzJ8nJBd15kpO1NQ",
  "certSha256": "FE96CC14A37C1881BB9A65AF5464277D15ABA1E6E8241C39DFED002D3724BE0C"
}
