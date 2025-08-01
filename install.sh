#!/bin/bash
#
# PulseVPN Server Universal Installer (x86_64 + ARM64)
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
echo -e "${BOLD}Personal VPN Server Universal Installer${NC}"
echo

# Detect architecture
ARCH=$(uname -m)
echo "🔍 Detected architecture: $ARCH"

case $ARCH in
    x86_64)
        echo "🚀 Installing PulseVPN server (Outline-based) for x86_64..."
        INSTALLER_URL="https://raw.githubusercontent.com/Jigsaw-Code/outline-apps/master/server_manager/install_scripts/install_server.sh"
        ;;
    aarch64|arm64)
        echo "🚀 Installing PulseVPN server (Outline-based) for ARM64..."
        # For ARM64, we use the same installer but need to handle potential issues
        INSTALLER_URL="https://raw.githubusercontent.com/Jigsaw-Code/outline-server/master/src/server_manager/install_scripts/install_server.sh"
        echo -e "${YELLOW}Note: ARM64 support - using official Outline server installer${NC}"
        ;;
    *)
        echo "❌ Unsupported architecture: $ARCH"
        echo "   Supported architectures: x86_64, aarch64 (ARM64)"
        exit 1
        ;;
esac

# Temporary file to capture output
temp_file=$(mktemp)

# Ensure Docker is available for ARM64
if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
    echo "🔧 Preparing ARM64 environment..."
    
    # Update package list
    apt-get update -qq
    
    # Install Docker if not present
    if ! command -v docker &> /dev/null; then
        echo "📦 Installing Docker for ARM64..."
        curl -fsSL https://get.docker.com | sh
        systemctl enable docker
        systemctl start docker
    fi
    
    # Check if ARM64 Docker images are available
    echo "🔍 Verifying ARM64 Docker support..."
    docker --version
fi

# Run installer and capture output
echo "⚡ Running installer..."
if wget -qO- "$INSTALLER_URL" | bash 2>&1 | tee "$temp_file"; then
    
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${GREEN}${BOLD}🎉 CONGRATULATIONS! Your PulseVPN server is up and running.${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    
    # Extract JSON config - improved regex for better matching
    json_config=$(grep -oE '\{"apiUrl":"[^"]*","certSha256":"[^"]*"\}' "$temp_file" | tail -1)
    
    # Alternative extraction if first method fails
    if [ -z "$json_config" ]; then
        json_config=$(grep -A 10 -B 5 "apiUrl" "$temp_file" | grep -oE '\{[^}]*"apiUrl"[^}]*\}' | tail -1)
    fi
    
    if [ -n "$json_config" ]; then
        echo -e "${BLUE}${BOLD}PulseVPN JSON configuration:${NC}"
        echo
        echo -e "${GREEN}$json_config${NC}"
        echo
        
        # Extract server details for manual configuration
        api_url=$(echo "$json_config" | grep -o '"apiUrl":"[^"]*"' | cut -d'"' -f4)
        server_ip=$(echo "$api_url" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
        
        echo -e "${BLUE}📱 Client Setup:${NC}"
        echo "• Download Outline Manager: https://getoutline.org/get-started/#step-3"
        echo "• Copy JSON configuration above into Outline Manager"
        echo "• Or use any Shadowsocks client with server: $server_ip"
        echo
        
        # Rename container for better identification
        if docker ps -a | grep -q shadowbox; then
            docker rename shadowbox pulsevpn-server 2>/dev/null || true
            echo "📦 Docker container renamed to: pulsevpn-server"
        fi
        
        # Save config
        mkdir -p /opt/pulsevpn
        echo "$json_config" > /opt/pulsevpn/config.json
        chmod 600 /opt/pulsevpn/config.json
        
        echo
        echo -e "${GREEN}📊 Management Commands:${NC}"
        echo "• View logs:    docker logs -f pulsevpn-server"
        echo "• Restart:      docker restart pulsevpn-server"
        echo "• Stop:         docker stop pulsevpn-server"
        echo "• Status:       docker ps | grep pulsevpn"
        echo
        echo "• Configuration file: /opt/pulsevpn/config.json"
        
        # Open firewall ports
        echo "🔥 Configuring firewall..."
        if command -v ufw &> /dev/null; then
            # Get the port from API URL or use default
            outline_port=$(echo "$api_url" | grep -oE ':[0-9]+' | cut -d':' -f2)
            if [ -n "$outline_port" ]; then
                ufw allow "$outline_port" 2>/dev/null || true
                echo "• Opened port: $outline_port"
            fi
        fi
        
    else
        echo -e "${YELLOW}⚠️  Installation completed but JSON configuration not extracted${NC}"
        echo "Please check the installation output above for the configuration details"
        echo
        echo "You can also check Docker containers:"
        echo "docker ps"
        echo "docker logs shadowbox"
    fi
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${GREEN}${BOLD}✅ Installation completed successfully!${NC}"
    echo "Architecture: $ARCH"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
else
    echo
    echo "❌ Installation failed. Check the error above."
    echo "Full log available at: $temp_file"
    exit 1
fi

# Cleanup
rm -f "$temp_file"

echo
echo -e "${BLUE}🔗 Useful links:${NC}"
echo "• Outline Manager: https://getoutline.org/get-started/"
echo "• Outline clients: https://getoutline.org/get-started/#step-3"
echo "• Support: https://support.getoutline.org/"
