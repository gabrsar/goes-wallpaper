#!/bin/bash

# Directory to save the images
SAVE_DIR="/home/gabriel/gabriel/projetos/goes/data"

# Ensure the directory exists
mkdir -p "$SAVE_DIR"

# set as false to keep only current file
KEEP_FILES=true

# Find the url you want to download and change target as the begin of the name of the file resolution size.
# URL of the page to scrape
FULL_DISK_PAGE_URL="https://www.star.nesdis.noaa.gov/GOES/fulldisk.php?sat=G16"
FULL_DISK_TARGET='5424' #5424 x 5424 px, (JPG, 14.04 MB)
FULL_DISK_NAME="FD"


SSA_PAGE_URL="https://www.star.nesdis.noaa.gov/GOES/sector.php?sat=G16&sector=ssa"
SSA_TARGET='7200' #7200 x 4320 px, (JPG, 10.12 MB)
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
    fi

    echo "downloading images..."
    full_disk=$(download_image "$FULL_DISK_PAGE_URL" "$SAVE_DIR/$FULL_DISK_NAME-last_url.txt" "$FULL_DISK_NAME" "$FULL_DISK_TARGET")
    ssa=$(download_image "$SSA_PAGE_URL" "$SAVE_DIR/$SSA_NAME-last_url.txt" "$SSA_NAME" "$SSA_TARGET")

    rnd=$(shuf -i 1-2 -n 1)

    if [ "$rnd" -eq 1 ] && [ -n "$ssa" ]; then
        echo "ssa"
        /usr/bin/plasma-apply-wallpaperimage "$ssa"
    elif [ "$rnd" -eq 2 ] && [ -n "$full_disk" ]; then
        echo "fd"
        /usr/bin/plasma-apply-wallpaperimage "$full_disk"
    fi

    sleep "$INTERVAL"
done
