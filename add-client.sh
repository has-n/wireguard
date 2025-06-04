#!/bin/bash

# Exit on any error
set -e
# set -o pipefail # Optional: exit if any command in a pipeline fails

WG_SERVER_CONF="/etc/wireguard/wg0.conf"
SERVER_PUBLIC_KEY_FILE="/etc/wireguard/server_public.key"
CLIENT_BASE_DIR_WG="/etc/wireguard" # Where client keys are stored
USER_CLIENT_CONFIG_BASE_DIR=/etc/wireguard-clients # Where user-friendly .conf and .qr are stored

# --- Helper function to get server's public IP ---
get_server_public_ip() {
    local primary_interface
    primary_interface=$(ip route | grep '^default' | awk '{print $5}' | head -1)
    if [ -z "$primary_interface" ]; then
        echo "Warning: Could not determine the primary network interface automatically. Falling back to 'eth0'." >&2
        primary_interface="eth0"
    fi
    ip addr show dev "${primary_interface}" | grep -oP '(?<=inet\s)([0-9.]+)' | head -1
}


# --- 1. Check prerequisites ---
if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root. Please use sudo." >&2
  exit 1
fi

if [ ! -f "$WG_SERVER_CONF" ]; then
    echo "Error: Server configuration file '$WG_SERVER_CONF' not found." >&2
    echo "Please run the server setup script first." >&2
    exit 1
fi

if [ ! -f "$SERVER_PUBLIC_KEY_FILE" ]; then
    echo "Error: Server public key file '$SERVER_PUBLIC_KEY_FILE' not found." >&2
    exit 1
fi

# --- 2. Determine Server's WireGuard Private IP and Network CIDR ---
SERVER_WG_ADDRESS_LINE=$(grep -E "^\s*Address\s*=" "$WG_SERVER_CONF" | head -1)
if [ -z "$SERVER_WG_ADDRESS_LINE" ]; then
    echo "Error: Could not find 'Address' in $WG_SERVER_CONF" >&2
    exit 1
fi

SERVER_PRIVATE_IP_WITH_MASK=$(echo "$SERVER_WG_ADDRESS_LINE" | awk -F '=' '{print $2}' | tr -d '[:space:]') # e.g., 10.0.0.1/24
SERVER_PRIVATE_IP=$(echo "$SERVER_PRIVATE_IP_WITH_MASK" | cut -d'/' -f1)
SERVER_NETMASK_CIDR_NUM=$(echo "$SERVER_PRIVATE_IP_WITH_MASK" | cut -d'/' -f2)

IFS='.' read -r sip_octet1 sip_octet2 sip_octet3 sip_octet4 <<< "$SERVER_PRIVATE_IP"
SERVER_PRIVATE_NETWORK_CIDR="${sip_octet1}.${sip_octet2}.${sip_octet3}.0/${SERVER_NETMASK_CIDR_NUM}"

echo "Server WireGuard IP: ${SERVER_PRIVATE_IP}/${SERVER_NETMASK_CIDR_NUM}"
echo "Server WireGuard Network (for client's AllowedIPs): ${SERVER_PRIVATE_NETWORK_CIDR}"

# --- 3. Determine New Client Number and IP ---
EXISTING_PEER_COUNT=$(grep -c '\[Peer\]' "$WG_SERVER_CONF")
CLIENT_FILE_ID_NUM=$((EXISTING_PEER_COUNT + 1)) # For filenames like client2.conf, client3.conf

# Calculate the last octet for the new client's IP
# Server is usually .1, first client .2, second .3, etc.
# So, new client's last octet = server_last_octet + existing_peer_count + 1
NEW_CLIENT_LAST_OCTET=$((sip_octet4 + EXISTING_PEER_COUNT + 1))

if [ "$NEW_CLIENT_LAST_OCTET" -gt 254 ]; then
    echo "Error: Calculated client IP last octet ($NEW_CLIENT_LAST_OCTET) is too high. Max is 254." >&2
    echo "You may have reached the limit for this /${SERVER_NETMASK_CIDR_NUM} subnet or need manual IP assignment." >&2
    exit 1
fi

NEW_CLIENT_PRIVATE_IP="${sip_octet1}.${sip_octet2}.${sip_octet3}.${NEW_CLIENT_LAST_OCTET}"
CLIENT_NAME="client${CLIENT_FILE_ID_NUM}" # e.g. client2, client3

echo "New client will be: ${CLIENT_NAME}"
echo "New client WireGuard Private IP: ${NEW_CLIENT_PRIVATE_IP}"

# --- 4. Generate keys for the new client ---
CLIENT_PRIVATE_KEY_FILE="${CLIENT_BASE_DIR_WG}/${CLIENT_NAME}_private.key"
CLIENT_PUBLIC_KEY_FILE="${CLIENT_BASE_DIR_WG}/${CLIENT_NAME}_public.key"

echo "Generating keys for ${CLIENT_NAME}..."
wg genkey | tee "$CLIENT_PRIVATE_KEY_FILE" > /dev/null # Store private key
chmod 600 "$CLIENT_PRIVATE_KEY_FILE"
cat "$CLIENT_PRIVATE_KEY_FILE" | wg pubkey | tee "$CLIENT_PUBLIC_KEY_FILE" > /dev/null # Generate and store public key

NEW_CLIENT_PRIVATE_KEY_VALUE=$(cat "$CLIENT_PRIVATE_KEY_FILE")
NEW_CLIENT_PUBLIC_KEY_VALUE=$(cat "$CLIENT_PUBLIC_KEY_FILE")

# --- 5. Get Server's Public Key and Public IP (for client config) ---
SERVER_WG_PUBLIC_KEY_VALUE=$(cat "$SERVER_PUBLIC_KEY_FILE")
SERVER_PUBLIC_IP=$(get_server_public_ip)

if [ -z "$SERVER_PUBLIC_IP" ]; then
    echo "Error: Could not determine server's public IP address." >&2
    echo "Please set it manually in the client configuration." >&2
    SERVER_PUBLIC_IP="YOUR_SERVER_PUBLIC_IP_HERE" # Placeholder
fi

# --- 6. Add Peer to Server Configuration (wg0.conf) ---
echo "Adding new peer to $WG_SERVER_CONF..."
tee -a "$WG_SERVER_CONF" > /dev/null << EOF

[Peer]
# Client: ${CLIENT_NAME}
# Client WireGuard IP: ${NEW_CLIENT_PRIVATE_IP}
PublicKey = ${NEW_CLIENT_PUBLIC_KEY_VALUE}
AllowedIPs = ${NEW_CLIENT_PRIVATE_IP}/32
EOF

# --- 7. Create Client Configuration File ---
USER_CLIENT_DIR="${USER_CLIENT_CONFIG_BASE_DIR}/${CLIENT_NAME}"
mkdir -p "$USER_CLIENT_DIR"
CLIENT_CONFIG_FILE_OUTPUT="${USER_CLIENT_DIR}/${CLIENT_NAME}.conf" # User-friendly location

echo "Creating client configuration file: ${CLIENT_CONFIG_FILE_OUTPUT}"
cat << EOF > "$CLIENT_CONFIG_FILE_OUTPUT"
[Interface]
PrivateKey = ${NEW_CLIENT_PRIVATE_KEY_VALUE}
Address = ${NEW_CLIENT_PRIVATE_IP}/32
DNS = 1.1.1.1, 1.0.0.1

[Peer]
PublicKey = ${SERVER_WG_PUBLIC_KEY_VALUE}
Endpoint = ${SERVER_PUBLIC_IP}:51820
AllowedIPs = ${SERVER_PRIVATE_NETWORK_CIDR} 
PersistentKeepalive = 25
EOF

# Set permissions for the user-accessible config file
# Get current user if script is run with sudo
CALLING_USER=${SUDO_USER:-$(whoami)}
CALLING_GROUP=$(id -gn "$CALLING_USER")
chown -R "${CALLING_USER}:${CALLING_GROUP}" "${USER_CLIENT_CONFIG_BASE_DIR}"
chmod 700 "${USER_CLIENT_CONFIG_BASE_DIR}"
chmod 700 "$USER_CLIENT_DIR"
chmod 600 "$CLIENT_CONFIG_FILE_OUTPUT"

# --- 8. Generate QR code for the new client ---
CLIENT_QR_CODE_FILE="${USER_CLIENT_DIR}/${CLIENT_NAME}-qr.txt"
echo "Generating QR code: ${CLIENT_QR_CODE_FILE}"
qrencode -t ansiutf8 < "$CLIENT_CONFIG_FILE_OUTPUT" > "$CLIENT_QR_CODE_FILE"
chmod 600 "$CLIENT_QR_CODE_FILE"

# --- 9. Restart WireGuard to apply changes ---
echo "Restarting WireGuard service (wg-quick@wg0)..."
if systemctl is-active --quiet wg-quick@wg0; then
    systemctl restart wg-quick@wg0
else
    systemctl start wg-quick@wg0
fi
echo "WireGuard service restarted."

# --- 10. Output information ---
echo ""
echo "========================================"
echo "New client '${CLIENT_NAME}' added successfully!"
echo "========================================"
echo "Client WireGuard Private IP: ${NEW_CLIENT_PRIVATE_IP}"
echo ""
echo "Configuration files saved for user '$CALLING_USER' in: ${USER_CLIENT_DIR}"
echo "  - Config: ${CLIENT_CONFIG_FILE_OUTPUT}"
echo "  - QR Code: ${CLIENT_QR_CODE_FILE}"
echo ""
echo "To view the QR code in terminal:"
echo "cat ${CLIENT_QR_CODE_FILE}"
echo ""
echo "Server configuration $WG_SERVER_CONF has been updated."
echo "Current server status:"
wg show