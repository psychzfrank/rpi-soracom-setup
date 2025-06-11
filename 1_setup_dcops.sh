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

# Start logging
echo "===== DCOPS Setup Started at $(date) =====" >>"$LOGFILE"

# Set root password
run_cmd "Set root password" passwd

# Enable root SSH login
run_cmd "Backup SSH config" cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
run_cmd "Enable PermitRootLogin in SSH config" sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
run_cmd "Restart SSH service" systemctl restart ssh || service ssh restart

# Update and upgrade system packages
run_cmd "Update and upgrade apt packages" bash -c "apt update && apt upgrade -y"

# Install and configure UFW
run_cmd "Install UFW" apt install -y ufw
run_cmd "Allow SSH in UFW" ufw allow ssh
run_cmd "Allow TCP port 22 in UFW" ufw allow 22/tcp
run_cmd "Check UFW status" ufw status
run_cmd "Enable UFW firewall" ufw --force enable

# Add operator1 user
# run_cmd "Add user operator1" adduser --gecos "" operator1
# run_cmd "Set password for operator1" bash -c "echo 'operator1:operator1' | chpasswd"
# run_cmd "Add operator1 to dialout group" adduser operator1 dialout

# Install screen utility
run_cmd "Install screen package" apt install -y screen

# Ask about network setup
echo -n "Do you want to configure static Ethernet? (y/N): " > /dev/tty
read do_net < /dev/tty

if [[ "$do_net" =~ ^[Yy]$ ]]; then
    log_step "Network Configuration - Static IP"

    run_cmd "Show current network connections" nmcli con show

    # Prompt and read interface name
    echo -n "Enter interface name (e.g., eth0): " > /dev/tty
    read eth_if < /dev/tty

    # Prompt and read static IP
    echo -n "Enter static IP with CIDR (e.g., 108.1.2.2/30): " > /dev/tty
    read static_ip < /dev/tty

    # Prompt and read gateway
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

# Summary
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
