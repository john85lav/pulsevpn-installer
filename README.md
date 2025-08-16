# PulseVPN Server Installer

Professional VPN server installer with multiple protocol support including DPI bypass capabilities.

## 🚀 Quick Install Options

### Standard Installation (Shadowsocks)
```bash
curl -sSL https://raw.githubusercontent.com/john85lav/pulsevpn-installer/main/install.sh | sudo bash
```

### DPI Bypass Installation (XRay + Advanced Protocols)
```bash
curl -sSL https://raw.githubusercontent.com/john85lav/pulsevpn-installer/main/install-xray-dpi.sh | sudo bash
```

### Upgrade Existing Server to DPI Bypass
```bash
# First install standard PulseVPN, then add DPI bypass
curl -sSL https://raw.githubusercontent.com/john85lav/pulsevpn-installer/main/install.sh | sudo bash
curl -sSL https://raw.githubusercontent.com/john85lav/pulsevpn-installer/main/install-xray-dpi.sh | sudo bash
```

## 📋 Requirements

- Linux server (Ubuntu/Debian/CentOS/RHEL)
- Root access
- Internet connection
- Open ports (automatically configured)

## 🔧 What Each Installer Does

### Standard Installer (`install.sh`)
- **x86_64**: Installs Outline Server (official Shadowsocks implementation)
- **ARM64**: Installs Shadowsocks-libev with Docker
- Auto-detects architecture and chooses optimal method
- Provides basic VPN functionality

### DPI Bypass Installer (`install-xray-dpi.sh`)
- Installs XRay with advanced protocols
- **Shadowsocks-2022**: Latest version with DPI bypass
- **VLESS+XTLS-Vision**: Maximum performance protocol
- **VLESS+WebSocket**: CDN-compatible for blocked IPs
- SSL/TLS termination with automatic certificates
- Works on networks with Deep Packet Inspection (DPI)

## 🌐 Connection Methods

### Standard Installation Results

**For x86_64 (Outline):**
```json
{
  "apiUrl": "https://YOUR_IP:PORT/API_PATH",
  "certSha256": "CERTIFICATE_HASH"
}
```

**For ARM64 (Shadowsocks-libev):**
```json
{
  "server": "YOUR_IP",
  "port": 2080,
  "password": "YOUR_PASSWORD",
  "method": "chacha20-ietf-poly1305"
}
```

### DPI Bypass Installation Results

**Shadowsocks-2022 (Best for mobile networks):**
```
ss://MjAyMi1ibGFrZTMtYWVzLTEyOC1nY206[password]@your-server:8388/?outline=1
```

**VLESS+XTLS-Vision (Maximum performance):**
```
vless://[uuid]@your-domain:443?encryption=none&flow=xtls-rprx-vision&security=tls...
```

**VLESS+WebSocket (CDN compatible):**
```
vless://[uuid]@your-domain:443?encryption=none&type=ws&security=tls...
```

## 📱 Client Compatibility

### Standard Protocols
- ✅ Outline clients (all platforms)
- ✅ Shadowsocks clients (all platforms)
- ✅ PulseVPN iOS app

### DPI Bypass Protocols
- ✅ V2Ray/XRay clients
- ✅ Clash clients
- ✅ Sing-Box clients
- ✅ Nekoray/Nekobox
- ✅ v2rayNG (Android)
- ✅ Wings X (iOS)

## 🔒 Security Features

### Standard Installation
- ChaCha20-Poly1305 encryption
- Unique API keys per installation
- Automatic firewall configuration

### DPI Bypass Installation
- **Shadowsocks-2022**: Latest encryption with obfuscation
- **XTLS-Vision**: Advanced traffic masking
- **TLS 1.3**: Industry-standard encryption
- **Traffic Obfuscation**: Bypasses DPI detection
- **Domain Fronting**: Optional CDN routing

## 🛠️ Management Commands

### Standard Installation
```bash
# ARM64 systems
sudo /opt/pulsevpn/manage.sh {start|stop|restart|logs|status|config|test|remove}

# x86_64 systems  
docker {start|stop|restart|logs} pulsevpn-server
sudo /opt/pulsevpn/manage.sh config
```

### DPI Bypass Installation
```bash
sudo /opt/pulsevpn/dpi-manage.sh {start|stop|restart|status|config|logs|test|remove}

# Key commands:
sudo /opt/pulsevpn/dpi-manage.sh config    # Show connection URLs
sudo /opt/pulsevpn/dpi-manage.sh test      # Test DPI bypass
sudo /opt/pulsevpn/dpi-manage.sh logs      # View XRay logs
```

## 🌍 Use Cases

### When to Use Standard Installation
- ✅ Simple VPN setup
- ✅ Unrestricted networks
- ✅ Basic privacy needs
- ✅ ARM64 devices (Raspberry Pi, Oracle Cloud ARM)

### When to Use DPI Bypass Installation
- ✅ Mobile networks with restrictions
- ✅ Corporate firewalls
- ✅ Countries with internet censorship
- ✅ ISPs using Deep Packet Inspection
- ✅ Maximum performance requirements

## 🔧 Advanced Configuration

### Custom Domain Setup (DPI Bypass)
```bash
# During installation, enter your domain when prompted
# Example: vpn.yourdomain.com
# SSL certificate will be automatically obtained
```

### Port Configuration
- **Standard**: Automatically finds free ports
- **DPI Bypass**: Uses 8388 (SS), 443 (HTTPS), 8080 (API)
- Firewall rules automatically configured

### Multiple Servers
```bash
# Install on multiple servers for redundancy
# Each server gets unique credentials
# Load balance between servers for best performance
```

## 🐛 Troubleshooting

### Port Issues
```bash
# Check firewall status
sudo ufw status
sudo iptables -L

# Test connectivity
telnet YOUR_IP YOUR_PORT
```

### Container Issues
```bash
# Check Docker status
docker ps -a
docker logs pulsevpn-server

# Check XRay status (DPI bypass)
sudo systemctl status xray
sudo journalctl -u xray
```

### SSL Issues (DPI Bypass)
```bash
# Check certificate
sudo certbot certificates

# Manual certificate renewal
sudo certbot renew --dry-run
```

### Complete Reinstall
```bash
# Remove everything and start fresh
docker stop pulsevpn-server 2>/dev/null || true
docker rm pulsevpn-server 2>/dev/null || true
sudo systemctl stop xray nginx 2>/dev/null || true
sudo rm -rf /opt/pulsevpn /usr/local/etc/xray
sudo apt remove --purge docker.io nginx -y

# Then run installer again
```

## 🔄 Migration Guide

### From Standard to DPI Bypass
```bash
# Your existing installation will continue working
# DPI bypass adds new capabilities without breaking existing setup
curl -sSL https://raw.githubusercontent.com/john85lav/pulsevpn-installer/main/install-xray-dpi.sh | sudo bash
```

### Updating Configurations
```bash
# Standard installation
sudo /opt/pulsevpn/manage.sh config

# DPI bypass installation  
sudo /opt/pulsevpn/dpi-manage.sh config
```

## 📊 Performance Comparison

| Protocol | Speed | DPI Bypass | Mobile Compatibility | CDN Support |
|----------|-------|------------|---------------------|-------------|
| Shadowsocks (Legacy) | ⭐⭐⭐ | ❌ | ⭐⭐ | ❌ |
| Shadowsocks-2022 | ⭐⭐⭐⭐ | ✅ | ⭐⭐⭐⭐⭐ | ❌ |
| VLESS+XTLS-Vision | ⭐⭐⭐⭐⭐ | ✅ | ⭐⭐⭐⭐ | ❌ |
| VLESS+WebSocket | ⭐⭐⭐ | ✅ | ⭐⭐⭐ | ✅ |

## 🆘 Support

### Log Files
- Standard: `docker logs pulsevpn-server`
- DPI Bypass: `sudo journalctl -u xray`
- Nginx: `sudo journalctl -u nginx`

### Configuration Files
- Standard: `/opt/pulsevpn/config.json`
- DPI Bypass: `/opt/pulsevpn/dpi-bypass-config.json`
- XRay: `/usr/local/etc/xray/config.json`

### Testing Connectivity
```bash
# Standard installation
sudo /opt/pulsevpn/manage.sh test

# DPI bypass installation
sudo /opt/pulsevpn/dpi-manage.sh test

# Manual testing
curl -v telnet://YOUR_IP:YOUR_PORT
```

---

## 🔐 Security Best Practices

1. **Keep systems updated**: `sudo apt update && sudo apt upgrade`
2. **Monitor logs regularly**: Check for suspicious activity
3. **Use strong passwords**: Generated passwords are cryptographically secure
4. **Rotate credentials**: Reinstall periodically for new credentials
5. **Backup configurations**: Save your config files safely

## 📈 Recommended Deployment

### Single Server Setup
```bash
# For basic needs - choose one:
curl -sSL https://raw.githubusercontent.com/john85lav/pulsevpn-installer/main/install.sh | sudo bash
```

### High-Performance Setup
```bash
# For maximum capabilities:
curl -sSL https://raw.githubusercontent.com/john85lav/pulsevpn-installer/main/install-xray-dpi.sh | sudo bash
```

### Redundant Setup
```bash
# Install on multiple servers in different regions
# Use different protocols on different servers
# Configure client failover
```

---

**License**: MIT License  
**Compatibility**: Ubuntu 18.04+, Debian 9+, CentOS 7+, RHEL 7+  
**Architectures**: x86_64, ARM64 (aarch64)  
**Protocols**: Shadowsocks, Shadowsocks-2022, VLESS, VMess, Trojan
