# PulseVPN Server Installer

One-line installer for personal PulseVPN server with Shadowsocks protocol.

## Quick Install

```bash
curl -sSL https://raw.githubusercontent.com/john85lav/pulsevpn-installer/main/install.sh | sudo bash
```

## Requirements

- Linux server (Ubuntu/Debian/CentOS)
- Root access
- Internet connection
- Ports 2080 and 9000-9999 range available

## What it does

1. Auto-detects your server's public IP
2. Installs Docker if needed
3. Generates TLS certificates
4. Configures firewall rules
5. Starts PulseVPN/Shadowsocks server
6. Provides configuration for iOS app

## Result

After installation, you'll get:

### For PulseVPN iOS app:
```swift
Server(ip: "YOUR_IP", apiKey: "YOUR_KEY", port: YOUR_PORT, name: "My Server")
```

### For any Shadowsocks client:
```json
{
  "server": "YOUR_IP",
  "port": 2080,
  "password": "YOUR_API_KEY",
  "method": "chacha20-ietf-poly1305",
  "apiUrl": "https://YOUR_IP:YOUR_API_PORT",
  "apiKey": "YOUR_API_KEY",
  "certSha256": "CERT_HASH"
}
```

## Management

```bash
# View logs
docker logs -f pulsevpn-server

# Restart server
docker restart pulsevpn-server

# Stop server
docker stop pulsevpn-server

# View configuration
cat /opt/pulsevpn/config_summary.txt
```

## Troubleshooting

### Port issues
- Check firewall: `sudo ufw status`
- Test connectivity: `telnet YOUR_IP 2080`

### Container issues
- Check status: `docker ps`
- View logs: `docker logs pulsevpn-server`

### Reinstall
```bash
docker stop pulsevpn-server
docker rm pulsevpn-server
rm -rf /opt/pulsevpn
# Run installer again
```

## Security

- Uses chacha20-ietf-poly1305 encryption
- Generates unique API keys per installation
- Self-signed certificates with SHA-256 fingerprints
- Automatic firewall configuration
