#!/bin/bash

set -e
LOGFILE="/var/log/soracom_setup.log"
exec 2>>"$LOGFILE"

echo "===== Starting Soracom USB setup ====="

echo "Installing network-manager and usb-modeswitch..."
sudo apt-get install -y network-manager usb-modeswitch

SCRIPT_URL="https://soracom-files.s3.amazonaws.com/setup_air.sh"
SCRIPT_NAME="setup_air.sh"

echo "Downloading Soracom setup script..."
curl -fSL "$SCRIPT_URL" -o "$SCRIPT_NAME"

echo "Running Soracom setup script..."
sudo bash "$SCRIPT_NAME"

echo "Setup complete."


# 1. Update cmdline.txt to include usbcore.autosuspend=-1
CMDLINE_FILE="/boot/firmware/cmdline.txt"
if grep -q "usbcore.autosuspend=-1" "$CMDLINE_FILE"; then
    echo "usbcore.autosuspend=-1 already present in cmdline.txt"
else
    echo "Appending usbcore.autosuspend=-1 to cmdline.txt..."
    sudo sed -i 's/$/ usbcore.autosuspend=-1/' "$CMDLINE_FILE"
fi

# 2. Create udev rule for USB modeswitch
UDEV_RULE='/etc/udev/rules.d/40-usb_modeswitch.rules'
echo 'Creating udev rule for USB modeswitch...'
sudo tee "$UDEV_RULE" >/dev/null <<EOF
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="2c7c", ATTR{idProduct}=="0125", RUN+="/usr/sbin/usb_modeswitch -v 2c7c -p 0125 -J"
EOF

# 3. Reload udev rules
echo "Reloading udev rules..."
sudo udevadm control --reload-rules
sudo udevadm trigger

# 4. Prompt to reboot
echo "===== Soracom USB setup complete ====="
echo "Reboot required to apply changes."
read -p "Would you like to reboot now? (y/N): " confirm
if [[ "$confirm" =~ ^[Yy]$ ]]; then
    echo "Rebooting..."
    sudo reboot
else
    echo "Please reboot manually when ready."
fi

