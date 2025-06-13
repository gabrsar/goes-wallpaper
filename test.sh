echo "Fetching available satellites and sectors..."
PAGE=$(curl -s "https://www.star.nesdis.noaa.gov/GOES/")

# Extrai pares SAT e SECTOR|NAME
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

echo "${SAT_LIST[$INDEX]}" > "$HOME/.config/goes-sat"
echo "${SECTOR_LIST[$INDEX]}" > "$HOME/.config/goes-sector"
echo "Selected: G${SAT_LIST[$INDEX]} - ${SECTOR_LIST[$INDEX]} - ${NAME_LIST[$INDEX]}"
