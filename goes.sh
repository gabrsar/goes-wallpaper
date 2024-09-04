#!/bin/bash

set -vx
# Directory to save the images
SAVE_DIR="/home/gabriel/gabriel/projetos/goes/data"

# Ensure the directory exists
mkdir -p "$SAVE_DIR"

# URL of the page to scrape
FULL_DISK_PAGE_URL="https://www.star.nesdis.noaa.gov/GOES/fulldisk.php?sat=G16"
FULL_DISK_TARGET='5424'
FULL_DISK_NAME="FD"

SSA_PAGE_URL="https://www.star.nesdis.noaa.gov/GOES/sector.php?sat=G16&sector=ssa"
SSA_TARGET='7200'
SSA_NAME="SSA"

# Interval in seconds (10 minutes)
INTERVAL=600


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
      FILE_NAME="$SAVE_DIR/${NAME}_$(date +%Y%m%d%H%M%S).jpg"
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
    fi

    full_disk=$(download_image "$FULL_DISK_PAGE_URL" "$SAVE_DIR/$FULL_DISK_NAME-last_url.txt" "$FULL_DISK_NAME" "$FULL_DISK_TARGET")
    ssa=$(download_image "$SSA_PAGE_URL" "$SAVE_DIR/$SSA_NAME-last_url.txt" "$SSA_NAME" "$SSA_TARGET")

    rnd=$(shuf -i 1-2 -n 1)

    if [ "$rnd" -eq 1 ] && [ -n "$ssa" ]; then
        /usr/bin/plasma-apply-wallpaperimage "$ssa"
    elif [ "$rnd" -eq 2 ] && [ -n "$full_disk" ]; then
        /usr/bin/plasma-apply-wallpaperimage "$full_disk"
    fi

    sleep "$INTERVAL"
done
