#!/bin/bash

# Test script for goes.sh

echo "Testing goes.sh..."

# Get the directory of this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check if goes.sh exists
if [ ! -f "$SCRIPT_DIR/goes.sh" ]; then
    echo "Error: goes.sh not found in $SCRIPT_DIR"
    exit 1
fi

# Stop the service if it's running
echo "Stopping the service..."
"$SCRIPT_DIR/goes.sh" stop

# Wait a moment
sleep 2

# Start the service
echo "Starting the service..."
"$SCRIPT_DIR/goes.sh" start

# Wait a moment
sleep 2

# Check if the service is running
echo "Checking service status..."
"$SCRIPT_DIR/goes.sh" status

echo "Test completed."