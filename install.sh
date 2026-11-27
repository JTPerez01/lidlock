#!/bin/bash
# LidLock install script
# Installs the binary and configures passwordless sudo for pmset

set -e

INSTALL_PATH="/usr/local/bin/lidlock"
SUDOERS_FILE="/etc/sudoers.d/lidlock"

echo "=== LidLock Installer ==="
echo ""

# Check if binary exists
if [ ! -f "./lidlock" ]; then
    echo "Building LidLock..."
    xcrun swiftc -swift-version 5 -O main.swift -o lidlock -framework AppKit
fi

# Install binary
echo "Installing binary to $INSTALL_PATH..."
sudo cp ./lidlock "$INSTALL_PATH"
sudo chown root:wheel "$INSTALL_PATH"
sudo chmod 755 "$INSTALL_PATH"

# Configure sudoers
if [ ! -f "$SUDOERS_FILE" ]; then
    echo "Configuring passwordless sudo..."
    echo "$(whoami) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0" | sudo tee "$SUDOERS_FILE" > /dev/null
    sudo chown root:wheel "$SUDOERS_FILE"
    sudo chmod 440 "$SUDOERS_FILE"
else
    echo "Sudoers entry already exists at $SUDOERS_FILE"
fi

# Verify
echo ""
echo "Verifying setup..."
sudo -n -l /usr/bin/pmset -a disablesleep 1 >/dev/null
sudo -n -l /usr/bin/pmset -a disablesleep 0 >/dev/null

echo ""
echo "=== LidLock installed! ==="
echo "Launch: $INSTALL_PATH"
echo "To uninstall: sudo rm $INSTALL_PATH $SUDOERS_FILE"
