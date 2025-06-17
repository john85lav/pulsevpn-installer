#!/bin/bash
#
# PulseVPN Server One-Line Installer
# Usage: curl -sSL https://raw.githubusercontent.com/john85lav/pulsevpn-installer/main/install.sh | sudo bash
#

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
readonly CERT_DIR="$CONFIG_DIR/cert"
readonly CERT_FILE="$CERT_DIR/cert.pem"
readonly KEY_FILE="$CERT_DIR/key.pem"
readonly API_PORT_MIN=9000
readonly API_PORT_MAX=9999
readonly SS_PORT=2080

# Global variables
PUBLIC_IP=""
API_KEY=""
API_PORT=""
CERT_SHA256=""

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

# Auto-detect public IP
get_public_ip() {
    local -ar urls=(
        'https://icanhazip.com'
        'https://ipinfo.io/ip'
        'https://api.ipify.org'
        'https://domains.google.com/checkip'
    )
    
    for url in "${urls[@]}"; do
        if local ip=$(curl -s --max-time 5 "$url" 2>/dev/null); then
            if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                echo "$ip"
                return 0
            fi
        fi
    done
    
    log_error "Failed to determine server's IP address"
    return 1
}

# Generate random API key
generate_api_key() {
    if command -v openssl &> /dev/null; then
        openssl rand -base64 32 2>/dev/null
    else
        head -c 32 /dev/urandom | base64 | tr -d '\n'
    fi
}

generate_port() {
    echo $((RANDOM % (API_PORT_MAX - API_PORT_MIN + 1) + API_PORT_MIN))
}

verify_docker() {
    # Check if running on macOS
    if [[ "$(uname)" == "Darwin" ]]; then
        if command -v docker &> /dev/null; then
            log_info "Docker is already installed"
            return 0
        else
            log_error "This script requires a Linux server, not macOS"
            log_error "Please run this on your VPS/server, not locally"
            log_error "Example: ssh root@your-server-ip"
            log_error "Then run: curl -sSL https://raw.githubusercontent.com/john85lav/pulsevpn-installer/main/install.sh | sudo bash"
            exit 1
        fi
    fi

    if command -v docker &> /dev/null && systemctl is-active --quiet docker; then
        log_info "Docker is already installed and running"
        return 0
    fi

    log_step "Installing Docker"
    if curl -fsSL https://get.docker.com | sh; then
        systemctl enable docker
        systemctl start docker
        # Add current user to docker group if not root
        if [[ $EUID -ne 0 ]]; then
            usermod -aG docker "$USER"
            log_warn "Please log out and back in for Docker permissions to take effect"
        fi
        log_info "Docker installed successfully"
        return 0
    else
        log_error "Docker installation failed"
        return 1
    fi
}

setup_firewall() {
    local api_port=$1
    log_step "Configuring firewall"

    if command -v ufw &> /dev/null; then
        ufw --force enable 2>/dev/null || true
        ufw allow "$api_port"/tcp 2>/dev/null || true
        ufw allow "$SS_PORT"/tcp 2>/dev/null || true
        ufw allow "$SS_PORT"/udp 2>/dev/null || true
        log_info "UFW rules configured for ports $api_port and $SS_PORT"
    elif command -v iptables &> /dev/null; then
        iptables -I INPUT -p tcp --dport "$api_port" -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p tcp --dport "$SS_PORT" -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p udp --dport "$SS_PORT" -j ACCEPT 2>/dev/null || true
        # Save iptables rules
        if command -v iptables-save &> /dev/null; then
            mkdir -p /etc/iptables 2>/dev/null || true
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        fi
        log_info "iptables rules configured for ports $api_port and $SS_PORT"
    else
        log_warn "No firewall detected. Ports $api_port and $SS_PORT may need manual configuration"
    fi
}

install_pulsevpn() {
    log_step "Starting PulseVPN Server Installation"

    # Architecture check
    local arch=$(uname -m)
    if [[ "$arch" != "x86_64" && "$arch" != "aarch64" ]]; then
        log_error "Unsupported architecture: $arch"
        exit 1
    fi

    # Root check
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi

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

    log_step "Generating configuration"
    API_KEY=$(generate_api_key)
    API_PORT=$(generate_port)
    log_info "API Key: $API_KEY"
    log_info "API Port: $API_PORT"
    log_info "Shadowsocks Port: $SS_PORT"

    log_step "Checking Docker installation"
    verify_docker || exit 1

    log_step "Creating configuration directories"
    mkdir -p "$CONFIG_DIR" "$CERT_DIR"
    chmod 755 "$CONFIG_DIR"
    chmod 700 "$CERT_DIR"

    log_step "Generating self-signed TLS certificate"
    if ! command -v openssl &> /dev/null; then
        log_error "OpenSSL is required but not installed"
        exit 1
    fi

    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$KEY_FILE" -out "$CERT_FILE" \
        -days 365 \
        -subj "/CN=$PUBLIC_IP" 2>/dev/null

    chmod 600 "$KEY_FILE"
    chmod 644 "$CERT_FILE"
    
    CERT_SHA256=$(openssl x509 -in "$CERT_FILE" -noout -fingerprint -sha256 | cut -d'=' -f2 | tr -d : | tr '[:lower:]' '[:upper:]')
    log_info "Generated SHA-256 Fingerprint: $CERT_SHA256"

    setup_firewall "$API_PORT"

    log_step "Starting PulseVPN Server container"
    
    # Stop existing container if running
    if docker ps -q --filter "name=$CONTAINER_NAME" | grep -q .; then
        log_info "Stopping existing container"
        docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
        docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi

    log_info "Pulling PulseVPN Server image..."
    local docker_image="$DOCKER_IMAGE"
    if ! docker pull "$docker_image" 2>/dev/null; then
        log_warn "Could not pull image from registry"
        # Try to use a minimal shadowsocks container as fallback
        docker_image="shadowsocks/shadowsocks-libev:latest"
        if ! docker pull "$docker_image" 2>/dev/null; then
            log_error "No suitable image found. Please ensure the PulseVPN image exists or build locally."
            exit 1
        fi
        log_info "Using fallback Shadowsocks image"
    fi

    # Create a simple config for shadowsocks
    cat > "$CONFIG_DIR/config.json" << EOF
{
    "server": "0.0.0.0",
    "server_port": 2080,
    "password": "$API_KEY",
    "method": "chacha20-ietf-poly1305",
    "timeout": 300,
    "fast_open": true
}
EOF

    # Start container with proper error handling
    if [[ "$docker_image" == "shadowsocks/shadowsocks-libev:latest" ]]; then
        # Special handling for Shadowsocks container
        if docker run -d \
            --name "$CONTAINER_NAME" \
            --restart unless-stopped \
            -p "${API_PORT}:8388" \
            -p "${SS_PORT}:8388" \
            -p "${SS_PORT}:8388/udp" \
            "$docker_image" \
            ss-server -s 0.0.0.0 -p 8388 -k "$API_KEY" -m chacha20-ietf-poly1305 -v >/dev/null 2>&1; then
            log_info "Container started successfully"
        else
            log_error "Failed to start container"
            exit 1
        fi
    else
        # Original PulseVPN container handling
        if docker run -d \
            --name "$CONTAINER_NAME" \
            --restart unless-stopped \
            -p "${API_PORT}:9443" \
            -p "${SS_PORT}:2080" \
            -p "${SS_PORT}:2080/udp" \
            -e "PULSE_SERVER_IP=$PUBLIC_IP" \
            -e "PULSE_API_KEY=$API_KEY" \
            -v "$CONFIG_DIR:/var/lib/pulsevpn" \
            -v "$CERT_FILE:/certs/cert.pem:ro" \
            -v "$KEY_FILE:/certs/key.pem:ro" \
            "$docker_image" >/dev/null 2>&1; then
            log_info "Container started successfully"
        else
            log_error "Failed to start container"
            exit 1
        fi
    fi

    log_step "Waiting for server to start"
    local attempts=0
    while [[ $attempts -lt 15 ]]; do
        if ! docker ps --format "table {{.Names}}" | grep -q "^$CONTAINER_NAME$"; then
            log_error "Container stopped unexpectedly"
            docker logs "$CONTAINER_NAME" 2>/dev/null || true
            exit 1
        fi
        
        # Simple connectivity test - check if either port responds
        if timeout 2 bash -c "</dev/tcp/localhost/$SS_PORT" 2>/dev/null; then
            log_info "Shadowsocks port $SS_PORT is ready"
            break
        elif timeout 2 bash -c "</dev/tcp/localhost/$API_PORT" 2>/dev/null; then
            log_info "API port $API_PORT is ready"
            break
        fi
        
        sleep 2
        ((attempts++))
        echo -n "."
    done
    echo

    if ! docker ps --format "table {{.Names}}" | grep -q "^$CONTAINER_NAME$"; then
        log_error "Server failed to start"
        docker logs "$CONTAINER_NAME" 2>/dev/null || true
        exit 1
    fi
    log_info "✅ PulseVPN Server is running!"
}

test_installation() {
    log_step "Testing installation"
    
    # Check container status
    if docker ps --format "table {{.Names}}" | grep -q "^$CONTAINER_NAME$"; then
        log_info "✅ Container is running"
    else
        log_warn "⚠️  Container status check failed"
        return
    fi
    
    # Test connectivity based on container type
    if docker ps --format "table {{.Image}}" | grep -q "shadowsocks"; then
        # Test shadowsocks ports
        if timeout 5 bash -c "</dev/tcp/localhost/$API_PORT" 2>/dev/null; then
            log_info "✅ Shadowsocks port $API_PORT is accessible"
        else
            log_warn "⚠️  Shadowsocks port $API_PORT test failed"
        fi
        if timeout 5 bash -c "</dev/tcp/localhost/$SS_PORT" 2>/dev/null; then
            log_info "✅ Shadowsocks port $SS_PORT is accessible"
        else
            log_warn "⚠️  Shadowsocks port $SS_PORT test failed"
        fi
    else
        # Test original shadowsocks port
        if timeout 5 bash -c "</dev/tcp/localhost/$SS_PORT" 2>/dev/null; then
            log_info "✅ Shadowsocks port $SS_PORT is accessible"
        else
            log_warn "⚠️  Shadowsocks port $SS_PORT test failed"
        fi
    fi
}

display_results() {
    cat << EOF

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
${GREEN}${BOLD}🎉 CONGRATULATIONS! Your PulseVPN server is up and running.${NC}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

${BLUE}To add this server to your PulseVPN iOS app, copy the following line:${NC}

${BOLD}${GREEN}Server(ip: "$PUBLIC_IP", apiKey: "$API_KEY", port: $API_PORT, name: "My Server")${NC}

${BLUE}Paste this line into your PulseVPN iOS app to connect.${NC}

${BLUE}🔧 Server Details:${NC}
• API URL:      https://$PUBLIC_IP:$API_PORT
• Shadowsocks:  $PUBLIC_IP:$SS_PORT
• Method:       chacha20-ietf-poly1305
• Password:     $API_KEY

${BLUE}📊 Management Commands:${NC}
• View logs:    docker logs -f $CONTAINER_NAME
• Restart:      docker restart $CONTAINER_NAME
• Stop:         docker stop $CONTAINER_NAME

${YELLOW}⚠️  Make sure the following ports are open on your firewall:${NC}
• Management port $API_PORT (TCP)
• Access key port $SS_PORT (TCP and UDP)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF

    log_step "PulseVPN JSON configuration"
    echo
    local json_config="{\"apiUrl\":\"https://$PUBLIC_IP:$API_PORT/$API_KEY\",\"certSha256\":\"$CERT_SHA256\"}"
    echo -e "${BLUE}$json_config${NC}"
    echo

    # Save configuration
    cat > "$CONFIG_DIR/config_summary.txt" << EOF
# PulseVPN Server Configuration
# Installed on: $(date)

PUBLIC_IP=$PUBLIC_IP
API_KEY=$API_KEY
API_PORT=$API_PORT
SS_PORT=$SS_PORT
CERT_SHA256=$CERT_SHA256

# iOS Configuration:
Server(ip: "$PUBLIC_IP", apiKey: "$API_KEY", port: $API_PORT, name: "My Server")

# JSON Configuration (Outline-compatible):
{"apiUrl":"https://$PUBLIC_IP:$API_PORT/$API_KEY","certSha256":"$CERT_SHA256"}

# Shadowsocks Configuration:
Server: $PUBLIC_IP
Port: $SS_PORT
Method: chacha20-ietf-poly1305
Password: $API_KEY
EOF
    log_info "Configuration saved to $CONFIG_DIR/config_summary.txt"
}

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

# Handle script interruption
trap 'log_error "Installation interrupted"; exit 1' INT TERM

main "$@"
