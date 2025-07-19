#!/bin/bash

LOGFILE="/var/log/dcops_setup.log"
ERRORS=()
touch "$LOGFILE"
exec 2>>"$LOGFILE"

log_step() {
    echo "==> $1"
}

run_cmd() {
    description="$1"
    shift
    log_step "$description"
    "$@"
    if [[ $? -ne 0 ]]; then
        ERRORS+=("$description")
        echo "ERROR during: $description" >>"$LOGFILE"
    fi
}

echo "===== DCOPS Setup Started at $(date) =====" >>"$LOGFILE"

# === Check and Run Soracom setup_air.sh ===
if [[ -f /etc/udev/rules.d/40-usb_modeswitch.rules ]]; then
    log_step "Soracom setup_air.sh already appears to have been run. Skipping."
else
    log_step "Downloading and running Soracom setup_air.sh"
    curl -fsSL https://soracom-files.s3.amazonaws.com/setup_air.sh -o /tmp/setup_air.sh
    chmod +x /tmp/setup_air.sh
    run_cmd "Run Soracom setup_air.sh" bash /tmp/setup_air.sh
fi

# === Additional modem reliability fixes ===

CMDLINE_FILE="/boot/firmware/cmdline.txt"
if grep -q "usbcore.autosuspend=-1" "$CMDLINE_FILE"; then
    echo "usbcore.autosuspend=-1 already present in cmdline.txt"
else
    echo "Appending usbcore.autosuspend=-1 to cmdline.txt..."
    run_cmd "Add usbcore.autosuspend=-1 to cmdline.txt" \
        sed -i 's/$/ usbcore.autosuspend=-1/' "$CMDLINE_FILE"
fi

UDEV_RULE='/etc/udev/rules.d/40-usb_modeswitch.rules'
log_step "Creating udev rule for USB modeswitch"
sudo tee "$UDEV_RULE" >/dev/null <<EOF
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="2c7c", ATTR{idProduct}=="0125", RUN+="/usr/sbin/usb_modeswitch -v 2c7c -p 0125 -J"
EOF

run_cmd "Reload udev rules" udevadm control --reload-rules
run_cmd "Trigger udev" udevadm trigger

# === System Customizations ===

run_cmd "Set root password. Hint: Type password once and hit Enter. Then type again and hit Enter again." passwd
run_cmd "Backup SSH config" cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
run_cmd "Enable PermitRootLogin in SSH config" sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
run_cmd "Restart SSH service" systemctl restart ssh || service ssh restart
run_cmd "Enable SSH on boot" systemctl enable ssh
run_cmd "Enable NTP time sync" timedatectl set-ntp true
run_cmd "Update and upgrade apt packages" bash -c "apt update && apt upgrade -y"

run_cmd "Install UFW" apt install -y ufw
run_cmd "Allow SSH in UFW" ufw allow ssh
run_cmd "Allow TCP port 22 in UFW" ufw allow 22/tcp
run_cmd "Set UFW to allow outbound" ufw default allow outgoing
run_cmd "Check UFW status" ufw status
run_cmd "Enable UFW firewall" ufw --force enable


# === Time sync script create ===


echo "Creating time sync script..."
cat <<'EOF' >/usr/local/bin/sync_time_ppp.sh
#!/bin/bash
LOGFILE="/var/log/sync_time_ppp.log"
exec >>"\$LOGFILE" 2>&1

echo "[\$(date)] Startup sync script running..."

# Wait for PPP interface
echo "Waiting for ppp0 interface..."
while ! ip a show ppp0 &>/dev/null; do sleep 1; done
echo "ppp0 is up!"

# Wait for internet (via ping)
echo "Waiting for internet connectivity..."
while ! ping -c 1 8.8.8.8 &>/dev/null; do sleep 1; done
echo "Internet is available."

# Sync time
echo "Restarting systemd-timesyncd to sync time..."
systemctl restart systemd-timesyncd

echo "[\$(date)] Time sync complete."
EOF

chmod +x /usr/local/bin/sync_time_ppp.sh

echo "Creating systemd service..."
cat <<EOF >/etc/systemd/system/sync-time-ppp.service
[Unit]
Description=Wait for PPP and sync time
After=network.target
Requires=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/sync_time_ppp.sh
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF

echo "Enabling sync-time-ppp.service..."
systemctl enable sync-time-ppp.service
# === Time sync script end ===


run_cmd "Install screen package" apt install -y screen

# === Optional: Static Ethernet Setup ===
echo -n "Do you want to configure static Ethernet? (y/N): " > /dev/tty
read do_net < /dev/tty

if [[ "$do_net" =~ ^[Yy]$ ]]; then
    log_step "Network Configuration - Static IP"
    run_cmd "Show current network connections" nmcli con show

    echo -n "Enter interface name (e.g., eth0): " > /dev/tty
    read eth_if < /dev/tty

    echo -n "Enter static IP with CIDR (e.g., 108.1.2.2/30): " > /dev/tty
    read static_ip < /dev/tty

    echo -n "Enter gateway (e.g., 108.1.2.1): " > /dev/tty
    read gateway < /dev/tty

    run_cmd "Add static-eth connection" \
        nmcli con add type ethernet con-name static-eth ifname "$eth_if" \
        ipv4.addresses "$static_ip" ipv4.gateway "$gateway" \
        ipv4.dns "1.1.1.1 8.8.8.8" ipv4.method manual

    run_cmd "Restart static-eth connection" \
        bash -c "nmcli con down static-eth && nmcli con up static-eth"

    run_cmd "Set static-eth priority to 100" \
        nmcli con modify static-eth connection.autoconnect-priority 100
    run_cmd "Set Wired connection 1 priority to 50" \
        nmcli con modify "Wired connection 1" connection.autoconnect-priority 50

    run_cmd "Enable autoconnect on static-eth" \
        nmcli con modify static-eth connection.autoconnect yes
    run_cmd "Enable autoconnect on Wired connection 1" \
        nmcli con modify "Wired connection 1" connection.autoconnect yes

    run_cmd "Set static-eth to retry 5 times" \
        nmcli con modify static-eth connection.autoconnect-retries 5
fi

# === Soracom GSM Setup via nmcli ===

run_cmd "Add Soracom GSM connection" \
    nmcli con add type gsm ifname "*" con-name soracom apn soracom.io user sora password sora

run_cmd "Restart NetworkManager" systemctl restart NetworkManager

run_cmd "Set Soracom connection priority" \
    nmcli con modify soracom connection.autoconnect-priority 20

run_cmd "Enable Soracom autoconnect" \
    nmcli con modify soracom connection.autoconnect yes

run_cmd "Set Soracom to retry 5 times" \
    nmcli con modify soracom connection.autoconnect-retries 5

# === Post-Setup Check ===
run_cmd "Check if Soracom modem ppp0 is up" ip a show ppp0
run_cmd "Show default route" ip route show default

# === Final Summary ===
echo
echo "===== DCOPS Setup Complete ====="
if [ ${#ERRORS[@]} -eq 0 ]; then
    echo "✅ All steps completed successfully!"
else
    echo "⚠️ The following steps had errors:"
    for step in "${ERRORS[@]}"; do
        echo " - $step"
    done
    echo "Check the log at: $LOGFILE"
fi
