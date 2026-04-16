#!/bin/bash
set -u

LOGFILE="/var/log/dcops_setup.log"
ERRORS=()

touch "$LOGFILE"
exec > >(tee -a "$LOGFILE") 2>&1

log_step() {
    echo
    echo "==> $1"
}

run_cmd() {
    local description="$1"
    shift
    log_step "$description"
    "$@"
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        ERRORS+=("$description")
        echo "ERROR during: $description (exit $rc)"
    fi
    return $rc
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

soracom_peer_exists() {
    [[ -d /etc/ppp/peers ]] || return 1
    find /etc/ppp/peers -maxdepth 1 -type f | grep -Eiq '/(soracom|soracom-air|air)$'
}

find_soracom_peer() {
    find /etc/ppp/peers -maxdepth 1 -type f 2>/dev/null \
        | sed 's|.*/||' \
        | grep -Ei '^(soracom|soracom-air|air)$' \
        | head -n1
}

echo "===== DCOPS Setup Started at $(date) ====="

# --- Basic package sanity ---
if ! command_exists curl; then
    run_cmd "Install curl" apt update
    run_cmd "Install curl package" apt install -y curl
fi

run_cmd "Install required packages" apt install -y \
    ppp usb-modeswitch modemmanager network-manager screen ufw

# --- Soracom setup ---
if soracom_peer_exists; then
    log_step "Soracom PPP peer already exists. Skipping setup_air.sh."
else
    log_step "Soracom PPP peer missing. Downloading and running Soracom setup_air.sh."
    run_cmd "Download Soracom setup_air.sh" \
        curl -fsSL https://soracom-files.s3.amazonaws.com/setup_air.sh -o /tmp/setup_air.sh
    run_cmd "Make setup_air.sh executable" chmod +x /tmp/setup_air.sh
    run_cmd "Run Soracom setup_air.sh" bash /tmp/setup_air.sh
fi

# --- Additional modem reliability fixes ---
CMDLINE_FILE="/boot/firmware/cmdline.txt"
if [[ -f "$CMDLINE_FILE" ]]; then
    if grep -q 'usbcore.autosuspend=-1' "$CMDLINE_FILE"; then
        log_step "usbcore.autosuspend=-1 already present in $CMDLINE_FILE"
    else
        run_cmd "Add usbcore.autosuspend=-1 to cmdline.txt" \
            sed -i 's|$| usbcore.autosuspend=-1|' "$CMDLINE_FILE"
    fi
else
    echo "WARNING: $CMDLINE_FILE not found; skipping usbcore.autosuspend change"
    ERRORS+=("cmdline.txt not found")
fi

UDEV_RULE='/etc/udev/rules.d/40-usb_modeswitch.rules'
log_step "Writing USB modeswitch udev rule"
cat > "$UDEV_RULE" <<'EOF'
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="2c7c", ATTR{idProduct}=="0125", RUN+="/usr/sbin/usb_modeswitch -v 2c7c -p 0125 -J"
EOF

run_cmd "Reload udev rules" udevadm control --reload-rules
run_cmd "Trigger udev" udevadm trigger

# --- SSH and system basics ---
run_cmd "Set root password" passwd
run_cmd "Backup SSH config" cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

if grep -qE '^[#[:space:]]*PermitRootLogin' /etc/ssh/sshd_config; then
    run_cmd "Enable PermitRootLogin in SSH config" \
        sed -i 's/^[#[:space:]]*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
else
    echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
fi

run_cmd "Restart SSH service" systemctl restart ssh
run_cmd "Enable SSH on boot" systemctl enable ssh
run_cmd "Enable NTP time sync" timedatectl set-ntp true
run_cmd "Update apt package lists" apt update
run_cmd "Upgrade apt packages" apt upgrade -y

# --- Firewall ---
run_cmd "Allow SSH in UFW" ufw allow ssh
run_cmd "Allow TCP port 22 in UFW" ufw allow 22/tcp
run_cmd "Set UFW default allow outgoing" ufw default allow outgoing
run_cmd "Enable UFW firewall" ufw --force enable
run_cmd "Check UFW status" ufw status verbose

# --- Time sync helper ---
cat > /usr/local/bin/check_and_sync_time.sh <<'EOF'
#!/bin/bash

if timedatectl status | grep -q "System clock synchronized: yes"; then
    echo "$(date): Time already synchronized."
    exit 0
fi

if ip a show ppp0 2>/dev/null | grep -q "inet "; then
    echo "$(date): ppp0 up."
elif ip a show wwan0 2>/dev/null | grep -q "inet "; then
    echo "$(date): wwan0 up."
else
    echo "$(date): No cellular network interface with IP, skipping time sync."
    exit 1
fi

if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
    echo "$(date): Internet available, restarting timesyncd..."
    systemctl restart systemd-timesyncd
else
    echo "$(date): No internet connectivity, skipping time sync."
    exit 1
fi
EOF

run_cmd "Make time sync helper executable" chmod +x /usr/local/bin/check_and_sync_time.sh

cat > /etc/systemd/system/check-time.service <<'EOF'
[Unit]
Description=Check and sync system time
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/check_and_sync_time.sh
EOF

cat > /etc/systemd/system/check-time.timer <<'EOF'
[Unit]
Description=Run time sync check every 2 hours

[Timer]
OnBootSec=5min
OnUnitActiveSec=2h
Persistent=true

[Install]
WantedBy=timers.target
EOF

run_cmd "Reload systemd daemon" systemctl daemon-reload
run_cmd "Enable and start check-time.timer" systemctl enable --now check-time.timer

# --- Optional: Static Ethernet Setup ---
echo -n "Do you want to configure static Ethernet? (y/N): " > /dev/tty
read -r do_net < /dev/tty

if [[ "$do_net" =~ ^[Yy]$ ]]; then
    log_step "Network Configuration - Static IP"
    run_cmd "Show current network connections" nmcli con show

    echo -n "Enter interface name (e.g., eth0): " > /dev/tty
    read -r eth_if < /dev/tty

    echo -n "Enter static IP with CIDR (e.g., 108.1.2.2/30): " > /dev/tty
    read -r static_ip < /dev/tty

    echo -n "Enter gateway (e.g., 108.1.2.1): " > /dev/tty
    read -r gateway < /dev/tty

    if nmcli -t -f NAME con show | grep -Fxq "static-eth"; then
        run_cmd "Modify existing static-eth connection" \
            nmcli con modify static-eth \
            ifname "$eth_if" ipv4.addresses "$static_ip" ipv4.gateway "$gateway" \
            ipv4.dns "1.1.1.1 8.8.8.8" ipv4.method manual connection.autoconnect yes
    else
        run_cmd "Add static-eth connection" \
            nmcli con add type ethernet con-name static-eth ifname "$eth_if" \
            ipv4.addresses "$static_ip" ipv4.gateway "$gateway" \
            ipv4.dns "1.1.1.1 8.8.8.8" ipv4.method manual connection.autoconnect yes
    fi

    run_cmd "Bring up static-eth connection" nmcli con up static-eth
    run_cmd "Set static-eth priority to 100" \
        nmcli con modify static-eth connection.autoconnect-priority 100
    run_cmd "Set static-eth to retry 5 times" \
        nmcli con modify static-eth connection.autoconnect-retries 5
fi

# --- Soracom via NetworkManager GSM profile ---
# This is optional and separate from PPP. It is kept guarded so it doesn't duplicate endlessly.
if nmcli -t -f NAME con show | grep -Fxq "soracom"; then
    log_step "NetworkManager Soracom profile already exists. Skipping add."
else
    run_cmd "Add Soracom GSM connection" \
        nmcli con add type gsm ifname "*" con-name soracom apn soracom.io user sora password sora
fi

run_cmd "Restart NetworkManager" systemctl restart NetworkManager
run_cmd "Enable Soracom autoconnect" nmcli con modify soracom connection.autoconnect yes
run_cmd "Set Soracom connection priority" nmcli con modify soracom connection.autoconnect-priority 20
run_cmd "Set Soracom to retry 5 times" nmcli con modify soracom connection.autoconnect-retries 5

# --- PPP recovery attempt if Soracom peer exists ---
SORACOM_PEER="$(find_soracom_peer)"
if [[ -n "${SORACOM_PEER:-}" ]]; then
    log_step "Found Soracom PPP peer: $SORACOM_PEER"
    if ! ip a show ppp0 2>/dev/null | grep -q "inet "; then
        run_cmd "Attempt to bring up Soracom PPP peer" pon "$SORACOM_PEER"
        sleep 10
    fi
else
    echo "WARNING: No Soracom PPP peer found after setup."
    ERRORS+=("No Soracom PPP peer found")
fi

# --- Post-setup checks ---
run_cmd "Show network devices" nmcli device status
run_cmd "Show interfaces" ip a
run_cmd "Show routes" ip route
run_cmd "Check if Soracom modem ppp0 is up" ip a show ppp0
run_cmd "Show default route" ip route show default

echo
echo "===== DCOPS Setup Complete ====="
if [[ ${#ERRORS[@]} -eq 0 ]]; then
    echo "✅ All steps completed successfully."
else
    echo "⚠️ The following steps had errors:"
    for step in "${ERRORS[@]}"; do
        echo " - $step"
    done
    echo "Check the log at: $LOGFILE"
fi
