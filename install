#!/bin/bash

# Define common settings
USERNAME=$(whoami)
CURRENT_DIR=$(pwd)
FETCH_SCRIPT="$CURRENT_DIR/goes-fetch"

# Make the scripts executable
chmod +x "$FETCH_SCRIPT"
chmod +x "$CURRENT_DIR/goes"

# Create a symlink for goes to be accessible from PATH
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    SYMLINK_DIR="/usr/local/bin"
else
    # Linux
    SYMLINK_DIR="$HOME/.local/bin"
    mkdir -p "$SYMLINK_DIR"
fi

# Create the symlink
if [ -f "$SYMLINK_DIR/goes" ]; then
    rm "$SYMLINK_DIR/goes"
fi
ln -s "$CURRENT_DIR/goes" "$SYMLINK_DIR/goes"
echo "Created symlink for 'goes' command in $SYMLINK_DIR"

# Ask user if they want to add the current folder to PATH
read -p "Do you want to add the current folder to your PATH? (y/n): " ADD_TO_PATH
if [[ "$ADD_TO_PATH" =~ ^[Yy]$ ]]; then
    # Determine which shell configuration file to use
    if [ -f "$HOME/.zshrc" ]; then
        SHELL_CONFIG="$HOME/.zshrc"
        echo "Found .zshrc"
    elif [ -f "$HOME/.bashrc" ]; then
        SHELL_CONFIG="$HOME/.bashrc"
        echo "Found .bashrc"
    else
        echo "Could not find .zshrc or .bashrc. Skipping PATH addition."
        SHELL_CONFIG=""
    fi

    if [ -n "$SHELL_CONFIG" ]; then
        echo "Adding $CURRENT_DIR to PATH in $SHELL_CONFIG"
        echo "# Added by GOES Wallpaper installer" >> "$SHELL_CONFIG"
        echo "export PATH=\"\$PATH:$CURRENT_DIR\"" >> "$SHELL_CONFIG"
        echo "Added current directory to PATH in $SHELL_CONFIG"
        echo "Please restart your terminal or run 'source $SHELL_CONFIG' to apply changes."
    fi
fi

# Fetch satellite data
echo "Fetching available satellites and sectors..."
PAGE=$(curl -s "https://www.star.nesdis.noaa.gov/GOES/")

LINES=$(echo "$PAGE" \
  | grep "<li>" \
  | grep "a href='sector.php" \
  | grep -v "channels" \
  | sed -E "s/.*sat=G([0-9]+)&sector=([^']+)'>\s*([^<]+).*/G\\1|\\2|\\3/" \
  | sort -u)

SAT_LIST=(); SECTOR_LIST=(); NAME_LIST=()
while IFS='|' read -r SAT SECTOR NAME; do
  SAT_LIST+=("$SAT")
  SECTOR_LIST+=("$SECTOR")
  NAME_LIST+=("$NAME")
done <<< "$LINES"

if [ ${#SECTOR_LIST[@]} -eq 0 ]; then
  echo "No sectors found. Aborting."
  exit 1
fi

echo "Select satellite + sector:"
for i in "${!SECTOR_LIST[@]}"; do
  printf "%2d) Satellite %s - %s - %s\n" $((i+1)) "${SAT_LIST[$i]}" "${SECTOR_LIST[$i]}" "${NAME_LIST[$i]}"
done

read -rp "Enter the number: " CHOICE
INDEX=$((CHOICE - 1))
if [[ -z "${SECTOR_LIST[$INDEX]}" ]]; then
  echo "Invalid choice. Aborting."
  exit 1
fi

# Create .config directory if it doesn't exist
mkdir -p "$HOME/.config"
echo "${SAT_LIST[$INDEX]}" > "$HOME/.config/goes-sat"
echo "${SECTOR_LIST[$INDEX]}" > "$HOME/.config/goes-sector"
echo "Selected: G${SAT_LIST[$INDEX]} - ${SECTOR_LIST[$INDEX]} - ${NAME_LIST[$INDEX]}"

# Detect operating system and run the appropriate installation script
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    echo "Detected macOS. Running macOS installation script..."
    chmod +x ./install-mac
    ./install-mac
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    # Linux
    echo "Detected Linux. Running Linux installation script..."
    chmod +x ./install-linux
    ./install-linux
else
    echo "Unsupported operating system: $OSTYPE"
    echo "This script supports macOS and Linux only."
    exit 1
fi
