#!/bin/bash

# Exit on any error
set -e

# --- Configuration Variables ---
# This is the IP address the WireGuard server will use on its virtual interface.
# Clients will connect to this network.
SERVER_PRIVATE_IP="10.0.0.1" 
SERVER_LISTEN_PORT="51820"
CLIENT_DNS="1.1.1.1, 1.0.0.1" # DNS for clients

# --- Derived Variables ---
# Calculate client IP (incrementing last octet of server IP)
IFS='.' read -r ip_octet1 ip_octet2 ip_octet3 ip_octet4 <<< "$SERVER_PRIVATE_IP"
client_last_octet=$((ip_octet4 + 1))
CLIENT_PRIVATE_IP="${ip_octet1}.${ip_octet2}.${ip_octet3}.${client_last_octet}"

# Calculate server private network CIDR
SERVER_PRIVATE_NETWORK_CIDR="${ip_octet1}.${ip_octet2}.${ip_octet3}.0/24"

# --- Paths for WireGuard configuration files ---
WG_DIR="/etc/wireguard"
SERVER_PRIVATE_KEY_FILE="${WG_DIR}/server_private.key"
SERVER_PUBLIC_KEY_FILE="${WG_DIR}/server_public.key"
CLIENT_PRIVATE_KEY_FILE="${WG_DIR}/client_private.key" 
CLIENT_PUBLIC_KEY_FILE="${WG_DIR}/client_public.key"   
SERVER_CONFIG_FILE="${WG_DIR}/wg0.conf"
CLIENT_CONFIG_FILE="${WG_DIR}/client.conf"             
CLIENT_QR_CODE_FILE="${WG_DIR}/client-qr.txt"          

echo "Server WireGuard Private Network CIDR: ${SERVER_PRIVATE_NETWORK_CIDR}"
echo "Server WireGuard Private IP will be: ${SERVER_PRIVATE_IP}"
echo "Client WireGuard Private IP will be: ${CLIENT_PRIVATE_IP}"
echo ""
# Pause for a moment for the user to see the IPs
sleep 3

# --- Package Installation ---
echo "Installing required packages..."
sudo apt update
sudo apt install wireguard ufw qrencode -y

# --- System Configuration ---
echo "Configuring IP forwarding..."
if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
  echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
fi
if ! grep -q "^net.ipv6.conf.all.forwarding=1" /etc/sysctl.conf; then
  echo "net.ipv6.conf.all.forwarding=1" | sudo tee -a /etc/sysctl.conf
fi
sudo sysctl -p

# --- WireGuard Directory ---
sudo mkdir -p "${WG_DIR}"
cd "${WG_DIR}" || { echo "Failed to change directory to ${WG_DIR}"; exit 1; }

# --- Key Generation ---
echo "Generating server keys..."
wg genkey | sudo tee "${SERVER_PRIVATE_KEY_FILE}"
sudo chmod 600 "${SERVER_PRIVATE_KEY_FILE}"
sudo cat "${SERVER_PRIVATE_KEY_FILE}" | wg pubkey | sudo tee "${SERVER_PUBLIC_KEY_FILE}"
sudo chmod 644 "${SERVER_PUBLIC_KEY_FILE}" 

echo "Generating client keys (for the first client)..."
wg genkey | sudo tee "${CLIENT_PRIVATE_KEY_FILE}"
sudo chmod 600 "${CLIENT_PRIVATE_KEY_FILE}"
sudo cat "${CLIENT_PRIVATE_KEY_FILE}" | wg pubkey | sudo tee "${CLIENT_PUBLIC_KEY_FILE}"
sudo chmod 644 "${CLIENT_PUBLIC_KEY_FILE}" 

# --- Determine Server Public IP ---
echo "Determining server public IP..."
PRIMARY_INTERFACE=$(ip route | grep '^default' | awk '{print $5}' | head -1)
if [ -z "$PRIMARY_INTERFACE" ]; then
  echo "Warning: Could not automatically determine the primary network interface."
  # Try to find an interface with a public IP
  PRIMARY_INTERFACE=$(ip -4 route get 8.8.8.8 | awk '{print $5}' | head -1)
  if [ -z "$PRIMARY_INTERFACE" ]; then
      echo "Error: Still could not determine the primary network interface. Please set SERVER_PUBLIC_IP manually in the script."
      # Fallback or ask user, for now we'll try eth0 if common
      PRIMARY_INTERFACE="eth0"
      echo "Warning: Falling back to use '${PRIMARY_INTERFACE}' for public IP. This might not be correct."
  else
      echo "Determined primary interface as: ${PRIMARY_INTERFACE}"
  fi
fi

SERVER_PUBLIC_IP=$(ip addr show dev "${PRIMARY_INTERFACE}" | grep -oP '(?<=inet\s)([0-9\.]+)' | head -1)
if [ -z "$SERVER_PUBLIC_IP" ]; then
  echo "Error: Could not determine the server's public IP address from interface ${PRIMARY_INTERFACE}."
  echo "Please find it manually and edit the client configuration file: ${CLIENT_CONFIG_FILE}"
  SERVER_PUBLIC_IP="YOUR_SERVER_PUBLIC_IP" # Placeholder
fi
echo "Server Public IP detected as: ${SERVER_PUBLIC_IP} on interface ${PRIMARY_INTERFACE}"

# --- Read Keys for Config Files ---
SERVER_WG_PRIVATE_KEY=$(sudo cat "${SERVER_PRIVATE_KEY_FILE}")
CLIENT_WG_PUBLIC_KEY=$(sudo cat "${CLIENT_PUBLIC_KEY_FILE}")

# --- Create Server Configuration (wg0.conf) ---
echo "Creating server configuration (${SERVER_CONFIG_FILE})..."
cat << EOF | sudo tee "${SERVER_CONFIG_FILE}"
[Interface]
PrivateKey = ${SERVER_WG_PRIVATE_KEY}
Address = ${SERVER_PRIVATE_IP}/24
ListenPort = ${SERVER_LISTEN_PORT}
PostUp = ufw route allow in on wg0 out on ${PRIMARY_INTERFACE}
PostUp = iptables -t nat -I POSTROUTING -o ${PRIMARY_INTERFACE} -j MASQUERADE
PostUp = ip6tables -t nat -I POSTROUTING -o ${PRIMARY_INTERFACE} -j MASQUERADE
PostDown = ufw route delete allow in on wg0 out on ${PRIMARY_INTERFACE}
PostDown = iptables -t nat -D POSTROUTING -o ${PRIMARY_INTERFACE} -j MASQUERADE
PostDown = ip6tables -t nat -D POSTROUTING -o ${PRIMARY_INTERFACE} -j MASQUERADE

[Peer] # This is for the first client
PublicKey = ${CLIENT_WG_PUBLIC_KEY}
AllowedIPs = ${CLIENT_PRIVATE_IP}/32
EOF
sudo chmod 600 "${SERVER_CONFIG_FILE}"

# --- Firewall Configuration ---
echo "Configuring firewall (UFW)..."
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow "${SERVER_LISTEN_PORT}/udp"
sudo ufw allow OpenSSH # Make sure SSH access is not blocked
# Ensure UFW is enabled, answer 'y' to the prompt if it asks
if ! sudo ufw status | grep -qw active; then
  echo "y" | sudo ufw enable
else
  echo "UFW is already active."
fi
sudo ufw reload # Apply changes

# --- Create Client Configuration (client.conf) ---
echo "<<<<<<>>>>>>"
echo "Creating client configuration (${CLIENT_CONFIG_FILE})..."
SERVER_WG_PUBLIC_KEY=$(sudo cat "${SERVER_PUBLIC_KEY_FILE}")
CLIENT_WG_PRIVATE_KEY=$(sudo cat "${CLIENT_PRIVATE_KEY_FILE}")

cat << EOF | sudo tee "${CLIENT_CONFIG_FILE}"
[Interface]
PrivateKey = ${CLIENT_WG_PRIVATE_KEY}
Address = ${CLIENT_PRIVATE_IP}/32
DNS = ${CLIENT_DNS} # For full tunneling. Remove or comment out for split tunnel if client manages DNS.

[Peer]
PublicKey = ${SERVER_WG_PUBLIC_KEY}
Endpoint = ${SERVER_PUBLIC_IP}:${SERVER_LISTEN_PORT}
AllowedIPs = ${SERVER_PRIVATE_NETWORK_CIDR} 
PersistentKeepalive = 25
EOF

echo "<<<<<<>>>>>>"

sudo chmod 600 "${CLIENT_CONFIG_FILE}" # Secure client config file

# --- Generate QR Code for Client ---
echo "Generating QR code (${CLIENT_QR_CODE_FILE})..."
# qrencode needs to read client.conf and write client-qr.txt
# Since client.conf is root-owned (600), qrencode needs to read it as root or via sudo cat
sudo bash -c "qrencode -t ansiutf8 < '${CLIENT_CONFIG_FILE}' > '${CLIENT_QR_CODE_FILE}'"
sudo chmod 600 "${CLIENT_QR_CODE_FILE}" # Secure QR code file, readable by root

# --- Start and Enable WireGuard Service ---
echo "Starting and enabling WireGuard service (wg-quick@wg0)..."
sudo systemctl enable wg-quick@wg0
sudo systemctl restart wg-quick@wg0 # Use restart to ensure changes are applied

# --- Display Information ---
echo "
========================================
WireGuard Installation Complete!
========================================

All WireGuard configurations are stored in: ${WG_DIR}

Server WireGuard Private IP: ${SERVER_PRIVATE_IP}/24
Client WireGuard Private IP: ${CLIENT_PRIVATE_IP}/32 (for the first client)

Server Information:
- Public IP: ${SERVER_PUBLIC_IP}
- Listening Port: ${SERVER_LISTEN_PORT}
- WireGuard Interface: wg0
- Server Config: ${SERVER_CONFIG_FILE}

Client Configuration (for the first client):
- Client Config File: ${CLIENT_CONFIG_FILE}
- QR Code (text format): ${CLIENT_QR_CODE_FILE}

To view the client configuration file:
sudo cat ${CLIENT_CONFIG_FILE}

To view the QR code for mobile clients:
sudo cat ${CLIENT_QR_CODE_FILE}
(You will need sudo to access these files as they are in /etc/wireguard)

To check WireGuard status:
sudo wg show
"

# --- Show WireGuard Status ---
echo "Current WireGuard status:"
sudo wg show

cd - > /dev/null # Return to previous directory silently
echo "Script finished."