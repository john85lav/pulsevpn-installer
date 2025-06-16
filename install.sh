#!/bin/bash
#
# PulseVPN Server One-Line Installer
# Usage: curl -sSL https://your-domain.com/install.sh | bash
#
# Based on Outline's approach but for personal use

set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# Configuration
readonly DOCKER_IMAGE="pulsevpn/server:latest"
readonly CONTAINER_NAME="pulsevpn-server"
readonly CONFIG_DIR="/opt/pulsevpn"
readonly API_PORT_MIN=9000
readonly API_PORT_MAX=9999
readonly SS_PORT=2080

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "\n${BLUE}${BOLD}> $1${NC}"
}

# Auto-detect public IP like Outline does
get_public_ip() {
    local -ar urls=(
        'https://icanhazip.com'
        'https://ipinfo.io/ip'
        'https://api.ipify.org'
        'https://domains.google.com/checkip'
    )
    
    for url in "${urls[@]}"; do
        if PUBLIC_IP=$(curl -s --max-time 5 "$url" 2>/dev/null); then
            # Validate IP format
            if [[ $PUBLIC_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                echo "$PUBLIC_IP"
                return 0
            fi
        fi
    done
    
    log_error "Failed to determine server's IP address"
    return 1
}

# Generate random API key like Outline
generate_api_key() {
    openssl rand -base64 32 2>/dev/null || head -c 32 /dev/urandom | base64
}

# Generate random port in safe range
generate_port() {
    echo $((RANDOM % (API_PORT_MAX - API_PORT_MIN + 1) + API_PORT_MIN))
}

# Check if Docker is installed and install if needed
verify_docker() {
    if command -v docker &> /dev/null; then
        log_info "Docker is already installed"
        return 0
    fi
    
    log_step "Installing Docker"
    if curl -fsSL https://get.docker.com | sh && systemctl enable docker && systemctl start docker; then
        log_info "Docker installed successfully"
        return 0
    else
        log_error "Docker installation failed"
        return 1
    fi
}

# Setup firewall rules
setup_firewall() {
    local api_port=$1
    
    log_step "Configuring firewall"
    
    # Try different firewall systems
    if command -v ufw &> /dev/null; then
        ufw allow "$api_port"/tcp 2>/dev/null || true
        ufw allow "$SS_PORT"/tcp 2>/dev/null || true
        ufw allow "$SS_PORT"/udp 2>/dev/null || true
        log_info "UFW rules configured for ports $api_port and $SS_PORT"
    elif command -v iptables &> /dev/null; then
        iptables -A INPUT -p tcp --dport "$api_port" -j ACCEPT 2>/dev/null || true
        iptables -A INPUT -p tcp --dport "$SS_PORT" -j ACCEPT 2>/dev/null || true
        iptables -A INPUT -p udp --dport "$SS_PORT" -j ACCEPT 2>/dev/null || true
        log_info "iptables rules configured for ports $api_port and $SS_PORT"
    else
        log_warn "No firewall detected. Ports $api_port and $SS_PORT may need manual configuration"
    fi
}

# Install and start PulseVPN server
install_pulsevpn() {
    log_step "Starting PulseVPN Server Installation"
    
    # System checks
    if [[ "$(uname -m)" != "x86_64" ]]; then
        log_error "Only x86_64 architecture is supported"
        exit 1
    fi
    
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
    
    # Get server IP
    log_step "Detecting public IP address"
    if ! PUBLIC_IP=$(get_public_ip); then
        echo -n "Enter your server's public IP address: "
        read -r PUBLIC_IP
        if [[ ! $PUBLIC_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            log_error "Invalid IP address format"
            exit 1
        fi
    fi
    log_info "Using IP: $PUBLIC_IP"
    
    # Generate credentials
    log_step "Generating configuration"
    API_KEY=$(generate_api_key)
    API_PORT=$(generate_port)
    
    log_info "API Key: $API_KEY"
    log_info "API Port: $API_PORT"
    log_info "Shadowsocks Port: $SS_PORT"
    
    # Install Docker
    log_step "Checking Docker installation"
    verify_docker || exit 1
    
    # Create directories
    log_step "Creating configuration directories"
    mkdir -p "$CONFIG_DIR"
    chmod 755 "$CONFIG_DIR"
    
    # Setup firewall
    setup_firewall "$API_PORT"
    
    # Pull and run container
    log_step "Starting PulseVPN Server container"
    
    # Stop existing container if running
    if docker ps -q --filter "name=$CONTAINER_NAME" | grep -q .; then
        log_info "Stopping existing container"
        docker stop "$CONTAINER_NAME" 2>/dev/null || true
        docker rm "$CONTAINER_NAME" 2>/dev/null || true
    fi
    
    # Try to pull image, fallback to build if not available
    log_info "Pulling PulseVPN Server image..."
    if ! docker pull "$DOCKER_IMAGE" 2>/dev/null; then
        log_warn "Could not pull image from registry, will use local build if available"
        # In personal use, you'd have the image built locally
        if ! docker images | grep -q "pulsevpn-server"; then
            log_error "No PulseVPN image found. Build locally first with: docker build -t pulsevpn-server:latest ."
            exit 1
        fi
        DOCKER_IMAGE="pulsevpn-server:latest"
    fi
    
    # Run the container
    docker run -d \
        --name "$CONTAINER_NAME" \
        --restart unless-stopped \
        -p "${API_PORT}:9443" \
        -p "${SS_PORT}:2080" \
        -p "${SS_PORT}:2080/udp" \
        -e "PULSE_SERVER_IP=$PUBLIC_IP" \
        -e "PULSE_API_KEY=$API_KEY" \
        -v "${CONFIG_DIR}:/var/lib/pulsevpn" \
        "$DOCKER_IMAGE"
    
    # Wait for startup
    log_step "Waiting for server to start"
    local attempts=0
    local max_attempts=30
    
    while [ $attempts -lt $max_attempts ]; do
        if docker ps | grep -q "$CONTAINER_NAME"; then
            if curl -s -k -H "Authorization: Bearer $API_KEY" \
                "https://localhost:$API_PORT/health" >/dev/null 2>&1; then
                break
            fi
        fi
        sleep 2
        ((attempts++))
        echo -n "."
    done
    echo
    
    if [ $attempts -eq $max_attempts ]; then
        log_error "Server failed to start properly"
        log_error "Check logs with: docker logs $CONTAINER_NAME"
        exit 1
    fi
    
    log_info "✅ PulseVPN Server is running!"
}

# Test the installation
test_installation() {
    log_step "Testing installation"
    
    # Test health endpoint
    if curl -s -k -H "Authorization: Bearer $API_KEY" \
        "https://$PUBLIC_IP:$API_PORT/health" | grep -q '"status":"ok"'; then
        log_info "✅ Health check passed"
    else
        log_warn "Health check failed - server may still be starting"
    fi
    
    # Test key creation
    TEST_KEY=$(curl -s -k -X POST \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json" \
        -d '{"name":"install-test","method":"chacha20-ietf-poly1305"}' \
        "https://$PUBLIC_IP:$API_PORT/access-keys" 2>/dev/null)
    
    if echo "$TEST_KEY" | grep -q '"accessUrl"'; then
        log_info "✅ Key creation test passed"
        # Clean up test key
        TEST_ID=$(echo "$TEST_KEY" | grep -o '"id":"[^"]*"' | cut -d'"' -f4)
        if [ -n "$TEST_ID" ]; then
            curl -s -k -X DELETE -H "Authorization: Bearer $API_KEY" \
                "https://$PUBLIC_IP:$API_PORT/access-keys/$TEST_ID" >/dev/null 2>&1
        fi
    else
        log_warn "Key creation test failed - check server logs"
    fi
}

# Display results like Outline does
display_results() {
    cat << EOF

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
${GREEN}${BOLD}🎉 PulseVPN Server Installation Complete!${NC}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

${BLUE}📱 Configuration for your iOS app:${NC}

${BOLD}Server(ip: "$PUBLIC_IP", apiKey: "$API_KEY", name: "My PulseVPN Server")${NC}

${BLUE}🔧 Server Details:${NC}
• API URL:      https://$PUBLIC_IP:$API_PORT
• Shadowsocks:  $PUBLIC_IP:$SS_PORT
• Method:       chacha20-ietf-poly1305

${BLUE}📊 Management Commands:${NC}
• View logs:    docker logs -f $CONTAINER_NAME
• Restart:      docker restart $CONTAINER_NAME
• Stop:         docker stop $CONTAINER_NAME
• Status:       docker ps | grep $CONTAINER_NAME

${YELLOW}⚠️  Important Notes:${NC}
• Save your API key securely - you'll need it for the iOS app
• Make sure ports $API_PORT and $SS_PORT are open in your cloud firewall
• The server will automatically restart on system reboot

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
    
    # Save configuration for future reference
    cat > "$CONFIG_DIR/install_config.txt" << EOF
# PulseVPN Server Configuration
# Installed on: $(date)

PUBLIC_IP=$PUBLIC_IP
API_KEY=$API_KEY
API_PORT=$API_PORT
SS_PORT=$SS_PORT

# iOS Configuration:
Server(ip: "$PUBLIC_IP", apiKey: "$API_KEY", name: "My PulseVPN Server")

# API URL: https://$PUBLIC_IP:$API_PORT
# Container: $CONTAINER_NAME
EOF
    
    log_info "Configuration saved to $CONFIG_DIR/install_config.txt"
}

# Main installation function
main() {
    echo -e "${BLUE}${BOLD}"
    cat << 'EOF'
    ____        __           _    ____  _   _ 
   |  _ \ _   _| |___  ___  | |  / ___|| \ | |
   | |_) | | | | / __|/ _ \ | | | |  _  |  \| |
   |  __/| |_| | \__ \  __/ | | | |_| | |\  |
   |_|    \__,_|_|___/\___| |_|  \____|_| \_|
                                            
EOF
    echo -e "${NC}"
    echo -e "${BOLD}Personal VPN Server Installer${NC}"
    echo
    
    install_pulsevpn
    test_installation
    display_results
}

# Run installation
main "$@"
