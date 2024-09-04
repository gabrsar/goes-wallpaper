#!/bin/bash

# Detect the current username
USERNAME=$(whoami)

# Define paths
SERVICE_TEMPLATE="goes.service"
SERVICE_FILE="$HOME/.config/systemd/user/goes.service"
CURRENT_DIR=$(pwd)
SCRIPT_FILE="$CURRENT_DIR/goes.sh"

chmod +x "$SCRIPT_FILE"

mkdir -p "$HOME/.config/systemd/user/"
cp "$SERVICE_TEMPLATE" "$SERVICE_FILE"

# Replace placeholders in the service file template with the detected username
sed "s#\$SCRIPT#${SCRIPT_FILE}#g" -i "$SERVICE_FILE"
sed "s#\$USERNAME#${USERNAME}#g" -i "$SERVICE_FILE"

# Enable and start the service
systemctl --user daemon-reload
systemctl --user stop goes.service
systemctl --user enable goes.service
systemctl --user start goes.service
systemctl --user status goes.service


echo "Service installed and started successfully."