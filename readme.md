# Real Time Earth Wallpaper

Data from NOAA satelittes GOES-16 / GOES-18. Those satelites are in a synchronous orbit at 36.000 km away from Earth, so they keep stationary over same spot and send back data every 10 minutes.

## Project Structure

The project is organized into several scripts:

- **goes-fetch.sh**: Common script that handles downloading satellite images
- **goes.sh**: Linux-specific script that sets the wallpaper
- **goes-mac.sh**: macOS-specific script that sets both wallpaper and lockscreen
- **install.sh**: Installation script for Linux
- **install-mac.sh**: Installation script for macOS

## More information
https://www.star.nesdis.noaa.gov/GOES/fulldisk.php?sat=G16
https://www.star.nesdis.noaa.gov/GOES/index.php

## Installation

### Linux
```bash
# Make the install script executable
chmod +x install.sh

# Run the installation script
./install.sh
```

### macOS
```bash
# Make the macOS install script executable
chmod +x install-mac.sh

# Run the macOS installation script
./install-mac.sh
```

The macOS version will:
- Change your desktop wallpaper with real-time Earth images
- Set the same image as your lockscreen background
- Start automatically when your computer turns on
- Pause when your computer is in battery saving mode (Low Power Mode)

## Service Management

Both the Linux and macOS versions now include command-line interfaces for managing the service.

### macOS

```bash
# Start the service
./goes-mac.sh start

# Stop the service
./goes-mac.sh stop

# Enable the service to start at login
./goes-mac.sh enable

# Disable the service from starting at login
./goes-mac.sh disable

# Check if the service is running
./goes-mac.sh status

# Run the service in the foreground (for debugging)
./goes-mac.sh
```

### Linux

```bash
# Start the service
./goes.sh start

# Stop the service
./goes.sh stop

# Enable the service to start at login
./goes.sh enable

# Disable the service from starting at login
./goes.sh disable

# Check if the service is running
./goes.sh status

# Run the service in the foreground (for debugging)
./goes.sh
```

If you encounter issues when trying to manage the service, try these steps:

1. Make sure you're running the commands from the same directory where the scripts are located
2. Make sure the scripts are executable (`chmod +x goes-mac.sh` or `chmod +x goes.sh`)
3. For macOS: Check the log file at `~/Library/Logs/goes-wallpaper.log` for any errors
4. For Linux: Check the logs with `journalctl --user -u goes.service`
5. Reinstall the service by running the appropriate installation script again

## Examples
![Exemple 1](./example1.png)
![Exemple 2](./example2.png)
![Exemple 3](./example3.png)
