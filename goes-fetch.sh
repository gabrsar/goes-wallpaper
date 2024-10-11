#!/bin/bash

# Directory to save the images - use absolute path for LaunchAgent compatibility
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAVE_DIR="$SCRIPT_DIR/.goes-wallpaper-data"

# Ensure the directory exists
mkdir -p "$SAVE_DIR"

# set as false to keep only current file
KEEP_FILES=true

# Array of configurations for the files to download
declare -a CONFIGS=(
  #PAGE URL; RESOLUTION WANTED (MUST BE THE FIRST ON THE PAGE); NAME TO SAVE;
  "https://www.star.nesdis.noaa.gov/GOES/fulldisk.php?sat=G16 10848 FD"
  "https://www.star.nesdis.noaa.gov/GOES/sector.php?sat=G16&sector=ssa 7200 SSA"
)

# Clean up old URL files if they exist
rm -f "$SAVE_DIR/*last-url.txt"

function download_image(){
  URL="$1"
  LAST_URL_FILE="$2"
  NAME="$3"
  TARGET="$4"

  PAGE_FILE="$SAVE_DIR/page.html"
  curl -s "$URL" > "$PAGE_FILE"
  URL_ADDRESS=$(cat "$PAGE_FILE" | grep "$TARGET" | head -n 1 | cut -d "=" -f 4 | cut -d "'" -f 2)

  touch "$LAST_URL_FILE"
  LAST_URL=$(cat "$LAST_URL_FILE" 2>/dev/null)

  if [ "$URL_ADDRESS" != "$LAST_URL" ]; then
      DATE_PREFIX=""
      if [ "$KEEP_FILES" = true ]; then
         DATE_PREFIX="_$(date +%Y%m%d%H%M%S)"
      fi
      FILE_NAME="$SAVE_DIR/${NAME}${DATE_PREFIX}.jpg"
      curl -s "$URL_ADDRESS" -o "$FILE_NAME"

      echo "$URL_ADDRESS" > "$LAST_URL_FILE"
      echo "$FILE_NAME"
  fi
}

# Main function to fetch images
fetch_images() {
    echo "Downloading images..." >&2
    downloaded_files=()

    for config in "${CONFIGS[@]}"; do
        IFS=' ' read -r -a params <<< "$config"
        file=$(download_image "${params[0]}" "$SAVE_DIR/${params[2]}-last_url.txt" "${params[2]}" "${params[1]}")
        if [ -n "$file" ]; then
            downloaded_files+=("$file")
        fi
    done

    # If we have downloaded files, output them as a space-separated list
    if [ ${#downloaded_files[@]} -gt 0 ]; then
        echo "${downloaded_files[@]}"
    fi
}

# Execute the fetch function and output the results
fetch_images
