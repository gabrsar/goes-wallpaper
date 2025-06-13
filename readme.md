# Real Time Earth Wallpaper

Data from NOAA satelittes GOES-16 / GOES-18. Those satelites are in a synchronous orbit at 36.000 km away from Earth, so they keep stationary over same spot and send back data every 10 minutes.

## Project Structure

The project is organized into several scripts:

- **goes-fetch**: Common script that handles downloading satellite images
- **goes**: Linux-specific script that sets the wallpaper
- **goes-mac**: macOS-specific script that sets both wallpaper and lockscreen
- **install**: Installation script for Linux and macOS
- **install-mac**: macOS-specific installation script
- **install-linux**: Linux-specific installation script

## More information
https://www.star.nesdis.noaa.gov/GOES/fulldisk.php?sat=G16
https://www.star.nesdis.noaa.gov/GOES/index.php

## Installation

### Linux and macOS
```bash
# Make the install script executable
chmod +x install

# Run the installation script
./install
```

The installation script will detect your operating system and run the appropriate installation steps. It will also ask if you want to add the current directory to your PATH variable in your shell configuration file (.bashrc or .zshrc).

The macOS version will:
- Change your desktop wallpaper with real-time Earth images
- Set the same image as your lockscreen background
- Start automatically when your computer turns on
- Pause when your computer is in battery saving mode (Low Power Mode)

## Service Management

Both the Linux and macOS versions include command-line interfaces for managing the service. If you added the directory to your PATH during installation, you can use the `goes` command from anywhere. Otherwise, you'll need to run the commands from the installation directory.

### Using the `goes` command

```bash
# Start the service
goes start

# Stop the service
goes stop

# Enable the service to start at login
goes enable

# Disable the service from starting at login
goes disable

# Check if the service is running
goes status

# Run the service in the foreground (for debugging)
goes
```

### Alternative: Using the scripts directly

#### macOS

```bash
# Start the service
./goes-mac start

# Stop the service
./goes-mac stop

# Enable the service to start at login
./goes-mac enable

# Disable the service from starting at login
./goes-mac disable

# Check if the service is running
./goes-mac status

# Run the service in the foreground (for debugging)
./goes-mac
```

#### Linux

```bash
# Start the service
./goes start

# Stop the service
./goes stop

# Enable the service to start at login
./goes enable

# Disable the service from starting at login
./goes disable

# Check if the service is running
./goes status

# Run the service in the foreground (for debugging)
./goes
```

If you encounter issues when trying to manage the service, try these steps:

1. Make sure you're running the commands from the same directory where the scripts are located (unless you added the directory to your PATH)
2. Make sure the scripts are executable (`chmod +x goes-mac` or `chmod +x goes`)
3. For macOS: Check the log file at `~/Library/Logs/goes-wallpaper.log` for any errors
4. For Linux: Check the logs with `journalctl --user -u goes.service`
5. Reinstall the service by running the installation script again

## Examples
![Exemple 1](./example1.png)
![Exemple 2](./example2.png)
![Exemple 3](./example3.png)
