#!/bin/bash

UPDATE_WALLPAPER_CMD="/usr/bin/plasma-apply-wallpaperimage"
# Directory to save the images
SAVE_DIR="$(pwd)/data"

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

rm "$SAVE_DIR/*last-url.txt"

# Interval in seconds (10 minutes)
INTERVAL=300

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
      if [ "$KEEP_FILES" ]; then
         DATE_PREFIX="_$(date +%Y%m%d%H%M%S)"
      fi
      FILE_NAME="$SAVE_DIR/${NAME}${DATE_PREFIX}.jpg"
      curl "$URL_ADDRESS" -o "$FILE_NAME"

      echo "$URL_ADDRESS" > "$LAST_URL_FILE"
      echo "$FILE_NAME"
  fi
}

while true; do
    ac_adapter=$(acpi -a | cut -d' ' -f3 | cut -d- -f1)

    if [ "$ac_adapter" != "on" ]; then
        echo "not on ac. waiting..."
        sleep "$INTERVAL"
        continue
    fi

    echo "downloading images..."
    downloaded_files=()

    for config in "${CONFIGS[@]}"; do
        IFS=' ' read -r -a params <<< "$config"
        file=$(download_image "${params[0]}" "$SAVE_DIR/${params[2]}-last_url.txt" "${params[2]}" "${params[1]}")
        if [ -n "$file" ]; then
            downloaded_files+=("$file")
        fi
    done

    if [ ${#downloaded_files[@]} -gt 0 ]; then
        rnd=$(shuf -i 0-$((${#downloaded_files[@]}-1)) -n 1)
        selected_file="${downloaded_files[$rnd]}"
        echo "Setting wallpaper to $selected_file"
        $UPDATE_WALLPAPER_CMD "$selected_file"
    fi

    sleep "$INTERVAL"
done
