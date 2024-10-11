#!/bin/bash

# Path to the fetching script
FETCH_SCRIPT="$(dirname "$0")/goes-fetch.sh"

# Interval in seconds (10 minutes)
INTERVAL=300

# Systemd service file path
SERVICE_FILE="$HOME/.config/systemd/user/goes.service"

# Function to display usage information
usage() {
    echo "Usage: $0 [command]"
    echo "Commands:"
    echo "  start    - Start the wallpaper service"
    echo "  stop     - Stop the wallpaper service"
    echo "  enable   - Enable the wallpaper service to start at login"
    echo "  disable  - Disable the wallpaper service from starting at login"
    echo "  status   - Check if the wallpaper service is running"
    echo "  (no args)- Run the wallpaper service in the foreground"
    exit 1
}

# Function to start the service
start_service() {
    echo "Starting GOES Wallpaper service..."
    systemctl --user start goes.service
    if [ $? -eq 0 ]; then
        echo "Service started successfully."
    else
        echo "Service failed to start. Check the logs with 'journalctl --user -u goes.service'"
    fi
}

# Function to stop the service
stop_service() {
    echo "Stopping GOES Wallpaper service..."
    systemctl --user stop goes.service
    if [ $? -eq 0 ]; then
        echo "Service stopped successfully."
    else
        echo "Service failed to stop or is not running."
    fi
}

# Function to enable the service
enable_service() {
    echo "Enabling GOES Wallpaper service to start at login..."
    systemctl --user enable goes.service
    if [ $? -eq 0 ]; then
        echo "Service enabled successfully."
    else
        echo "Failed to enable service. Make sure the service file exists."
        echo "If not, run the install.sh script first."
    fi
}

# Function to disable the service
disable_service() {
    echo "Disabling GOES Wallpaper service from starting at login..."
    systemctl --user disable goes.service
    if [ $? -eq 0 ]; then
        echo "Service disabled successfully."
    else
        echo "Failed to disable service or service is not enabled."
    fi
}

# Function to check service status
check_status() {
    systemctl --user status goes.service
}

# Parse command-line arguments
if [ $# -gt 0 ]; then
    case "$1" in
        start)
            start_service
            exit 0
            ;;
        stop)
            stop_service
            exit 0
            ;;
        enable)
            enable_service
            exit 0
            ;;
        disable)
            disable_service
            exit 0
            ;;
        status)
            check_status
            exit 0
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            echo "Unknown command: $1"
            usage
            ;;
    esac
fi

# If no arguments are provided, run the service in the foreground

set_wallpaper() {
    wallpaper_path="$1"
    if pgrep -x "i3" > /dev/null; then
        # i3 window manager
        feh --bg-scale "$wallpaper_path"
    elif pgrep -x "bspwm" > /dev/null; then
        # bspwm window manager
        feh --bg-scale "$wallpaper_path"
    elif pgrep -x "xfwm4" > /dev/null; then
        # Xfce
        xfconf-query --channel xfce4-desktop --property /backdrop/screen0/monitor0/workspace0/last-image --set "$wallpaper_path"
    elif pgrep -x "openbox" > /dev/null; then
        # Openbox
        feh --bg-scale "$wallpaper_path"
    elif pgrep -x "gnome-shell" > /dev/null; then
        # GNOME
        gsettings set org.gnome.desktop.background picture-uri "file://$wallpaper_path"
    elif pgrep -x "plasmashell" > /dev/null; then
				# you can try this too: 
				# /usr/bin/plasma-apply-wallpaperimage "$wallpaper_path"
        qdbus org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript \
        "var allDesktops = desktops(); \
        for (i = 0; i < allDesktops.length; i++) { \
            d = allDesktops[i]; \
            d.wallpaperPlugin = 'org.kde.image'; \
            d.currentConfigGroup = Array('Wallpaper', 'org.kde.image', 'General'); \
            d.writeConfig('Image', 'file://$wallpaper_path') \
        }"
    elif pgrep -x "awesome" > /dev/null; then
        # awesome window manager
        feh --bg-scale "$wallpaper_path"
    elif pgrep -x "sway" > /dev/null; then
        # sway (Wayland compositor)
        swaymsg output "*" bg "$wallpaper_path" fill
    elif pgrep -x "herbstluftwm" > /dev/null; then
        # herbstluftwm
        feh --bg-scale "$wallpaper_path"
    elif pgrep -x "enlightenment" > /dev/null; then
        # Enlightenment
        enlightenment_remote -desktop-bg-add 0 0 "$wallpaper_path"
    else
        # Fallback to feh if no window manager is detected
        feh --bg-scale "$wallpaper_path"
    fi
}


while true; do
    ac_adapter=$(acpi -a | cut -d' ' -f3 | cut -d- -f1)

    if [ "$ac_adapter" != "on" ]; then
        echo "not on ac. waiting..."
        sleep "$INTERVAL"
        continue
    fi

    # Call the fetch script to download images
    downloaded_files_str=$("$FETCH_SCRIPT")

    # Convert the space-separated string to an array
    IFS=' ' read -r -a downloaded_files <<< "$downloaded_files_str"

    if [ ${#downloaded_files[@]} -gt 0 ]; then
        rnd=$(shuf -i 0-$((${#downloaded_files[@]}-1)) -n 1)
        selected_file="${downloaded_files[$rnd]}"
        echo "Setting wallpaper to $selected_file"
        set_wallpaper "$selected_file"
    fi

    sleep "$INTERVAL"
done
