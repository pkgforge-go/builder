#!/usr/bin/env bash

#-------------------------------------------------------#
#Get inside a TEMP Dir
pushd "$(mktemp -d)" &>/dev/null
export TEMP_DIR="$(realpath .)"
export OUT_DIR="/tmp/pkgs"
rm -rf "${OUT_DIR}" 2>/dev/null ; mkdir -p "${OUT_DIR}/TEMP"
echo -e "\n[+] Using TEMP dir: ${TEMP_DIR}"
echo -e "[+] Using OUT dir: ${OUT_DIR}\n"
if [[ ! -d "${SYSTMP}" ]]; then
  SYSTMP="$(dirname $(mktemp -u))"
fi
#CUTOFF_DATE="$(date -d 'last year' '+%Y-01-01' | tr -d '[:space:]')"
#CUTOFF_DATE="$(date -d 'last month' '+%Y-%m-%d' | tr -d '[:space:]')"
#CUTOFF_DATE="$(date -d 'last week' '+%Y-%m-%d' | tr -d '[:space:]')"
#CUTOFF_DATE="$(date -d '2 days ago' '+%Y-%m-%d' | tr -d '[:space:]')"
CUTOFF_DATE="$(date -d '1 day ago' '+%Y-%m-%d' | tr -d '[:space:]')"
export CUTOFF_DATE SYSTMP
##Cmd
install_tool() {
    sudo curl -qfsSL "$2" -o "/usr/local/bin/$1"
    sudo chmod 'a+x' "/usr/local/bin/$1"
    hash -r &>/dev/null
    command -v "$1" &>/dev/null || { echo -e "\n[-] $1 NOT Found"; exit 1; }
}
install_tool "_detect_if_cli" "https://raw.githubusercontent.com/pkgforge-go/builder/refs/heads/main/scripts/_detect_if_cli.sh"
install_tool "filter-urls" "https://bin.pkgforge.dev/$(uname -m)-$(uname -s)/filter-urls"
install_tool "go-detector" "https://bin.pkgforge.dev/$(uname -m)-$(uname -s)/go-detector"
install_tool "go-indexer" "https://bin.pkgforge.dev/$(uname -m)-$(uname -s)/go-indexer"
install_tool "go-enricher" "https://bin.pkgforge.dev/$(uname -m)-$(uname -s)/go-enricher"
#-------------------------------------------------------#

#-------------------------------------------------------#
##Generate Dump: https://pkg.go.dev/about
 #https://index.golang.org/index
 go-indexer --start-date "${CUTOFF_DATE}" --output "${TEMP_DIR}/INDEX.jsonl" --verbose
 echo -e "\n[+] Processing RAW Packages\n"
##Process
 jq --arg cutoff_date "${CUTOFF_DATE}" \
 '
  def sanitize: if type == "string" then gsub("[`${}\\\\\"'\''();|&<>]"; "_") else . end;
  .[] 
  | select(
      (.source | ascii_downcase | test("^6github\\.com|go-micro\\.|kubevirt\\.|opentelemetry\\.|staging\\.|www\\.") | not)
      and
      (.source | ascii_downcase | endswith(".git") | not)
      and
      (.source | ascii_downcase | ltrimstr(" ") | test("^(bitbucket\\.org/|buildroot\\.net/|codeberg\\.org/|gitee\\.com/|github\\.com/|gitlab\\.com/|sr\\.ht/|sourceforge\\.net/)"))
      and
      (
        (.versions[-1] | split("-") | length != 3)
        or
        (.versions[-1] | split("-")[1] | .[0:8] | test("^\\d{8}$") and . >= ($cutoff_date[0:8]))
      )
    ) 
  | {
      source: .source, 
      version: .versions[-1],
      pkg_id: ((.source // "") | sub("^https?://"; "") | gsub("[^a-zA-Z0-9.-]"; "_")) | sanitize,
      download: ("https://proxy.golang.org/" + .source + "/@v/" + .versions[-1] + ".zip")
    }
 ' "${TEMP_DIR}/INDEX.processed.json" > "${TEMP_DIR}/RAW.json.tmp"
##Merge
 awk '/^\s*{\s*$/{flag=1; buffer="{\n"; next} /^\s*}\s*$/{if(flag){buffer=buffer"}\n"; print buffer}; flag=0; next} flag{buffer=buffer$0"\n"}' "${TEMP_DIR}/RAW.json.tmp" | jq -c '. as $line | (fromjson? | .message) // $line' >> "${TEMP_DIR}/RAW.json.raw"
 jq -s '[.[] | select(type == "object" and has("source"))] | unique_by(.source | ascii_downcase) | sort_by(.source | ascii_downcase) | walk(if type == "object" then with_entries(select(.value != null and .value != "" and .value != "null")) elif type == "boolean" or type == "number" then tostring else . end) | map(to_entries | sort_by(.key) | from_entries)' \
 "${TEMP_DIR}/RAW.json.raw" > "${TEMP_DIR}/RAW.json"
  if [[ "$(jq -r '.[] | .source' "${TEMP_DIR}/RAW.json" | grep -Eiv '^null$' | sort -u | wc -l | tr -cd '[:digit:]')" -ge 1000 ]]; then
     cp -fv "${TEMP_DIR}/RAW.json" "${OUT_DIR}/RAW.json"
  else
     echo -e "\n[✗] FATAL: Failed to parse PKG Data Lists\n"
    exit 1
  fi
##Enrich
  go-enricher --input "${OUT_DIR}/RAW.json" --output "${TEMP_DIR}/PKG_DUMP.json.tmp" --threads "50" --force
  jq \
   '
    map(select(.description != "No Description Provided")) |
    map(select(
      has("download") and 
      has("source") and 
      has("version")
    )) |
    map(select(
      (has("stars") | not) or 
      (.stars | tonumber >= -1)
    )) |
    map(
      if (has("homepage") | not) or 
         .homepage == "" or 
         .homepage == null 
      then 
        .homepage = "https://" + .source 
      else 
        . 
      end
    ) |
    unique_by(.source) |
    sort_by(.source)
  ' "${TEMP_DIR}/PKG_DUMP.json.tmp" > "${TEMP_DIR}/PKG_DUMP.json"
  echo -e "\n[+] Merging enriched Data\n"
  jq -s \
  '
   (.[1] | reduce .[] as $item ({}; .[$item.source] = $item)) as $pkg_lookup |
   .[0] | map(select($pkg_lookup[.source]) | . + $pkg_lookup[.source] | 
     if (.source | test("^(bitbucket\\.org|codeberg\\.org|gitee\\.com|github\\.com|gitlab\\.com|sr\\.ht|sourceforge\\.net)/"))
     then . + {"clone": ("https://" + (.source | split("/") | .[0:3] | join("/")) + ".git")}
     else .
     end |
     if (.version | split("-") | length > 1 and (.[1] | test("^[0-9]{8}[0-9]{6}$")))
     then 
       (.version | split("-")[1] | 
        . as $datestr |
        ($datestr[0:4] + "-" + $datestr[4:6] + "-" + $datestr[6:8] + "T" + $datestr[8:10] + ":" + $datestr[10:12] + ":" + $datestr[12:14] + "Z") | 
        strptime("%Y-%m-%dT%H:%M:%SZ") | todate) as $formatted_date |
       . + {"updated_at": $formatted_date}
     else . + {"updated_at": (now | todate)}
     end
   )
  ' "${OUT_DIR}/RAW.json" "${TEMP_DIR}/PKG_DUMP.json" > "${TEMP_DIR}/PKG_DUMP.json.tmp"
  if [[ "$(jq -r '.[] | .source' "${TEMP_DIR}/PKG_DUMP.json.tmp" | grep -Eiv '^null$' | sort -u | wc -l | tr -cd '[:digit:]')" -ge 1000 ]]; then
     cp -fv "${TEMP_DIR}/PKG_DUMP.json.tmp" "${TEMP_DIR}/PKG_DUMP.json"
  else
     echo -e "\n[✗] FATAL: Failed to enrich PKG Data Lists\n"
    exit 1
  fi
##Check if CLI
   echo -e "\n[+] Total Download URLs: $(jq -r '.[] | .download' "${TEMP_DIR}/PKG_DUMP.json" | grep -Eiv '^null$' | sort -u | wc -l)\n"
   jq -r '.[] | .download' "${TEMP_DIR}/PKG_DUMP.json" | grep -Eiv '^null$' | sort -u | filter-urls --concurrency "30" --output "${TEMP_DIR}/urls.tmp"
   sort -u "${TEMP_DIR}/urls.tmp" -o "${TEMP_DIR}/urls.tmp"
   sed -E 's/^[[:space:]]+|[[:space:]]+$//g' -i "${TEMP_DIR}/urls.tmp"
   echo -e "[+] Filtered Download URLs: $(wc -l < "${TEMP_DIR}/urls.tmp")\n"
   echo -e "\n[+] Filtering CLI PKGs ...\n"
   > "${TEMP_DIR}/DETECTION.json.raw"
   go-detector --input "${TEMP_DIR}/urls.tmp" --workers "50" --json &> "${TEMP_DIR}/DETECTION.json.raw"
     awk \
      '
       BEGIN {
           print "["
           first_entry = 1
       }
       /type_string/ {
           if (match($0, /"type_string"[[:space:]]*:[[:space:]]*"([^"]*)"/, type_match)) {
               type_value = type_match[1]
               
               remote_found = 0
               remote_value = ""
               
               while ((getline next_line) > 0) {
                   if (next_line ~ /remote_source/) {
                       if (match(next_line, /"remote_source"[[:space:]]*:[[:space:]]*"([^"]*)"/, remote_match)) {
                           remote_value = remote_match[1]
                           remote_found = 1
                       }
                       break
                   }
                   if (next_line ~ /type_string/) {
                       # Push back the line by storing it for next iteration
                       pushback_line = next_line
                       break
                   }
               }
               
               if (remote_found && remote_value != "") {
                   if (!first_entry) {
                       print ","
                   }
                   printf "  {\n"
                   printf "    \"type_string\": \"%s\",\n", type_value
                   printf "    \"remote_source\": \"%s\"\n", remote_value
                   printf "  }"
                   first_entry = 0
               }
               
               if (pushback_line != "") {
                   $0 = pushback_line
                   pushback_line = ""
                   
                   if (match($0, /"type_string"[[:space:]]*:[[:space:]]*"([^"]*)"/, type_match)) {
                       type_value = type_match[1]
                       remote_found = 0
                       remote_value = ""
                       
                       while ((getline next_line) > 0) {
                           if (next_line ~ /remote_source/) {
                               if (match(next_line, /"remote_source"[[:space:]]*:[[:space:]]*"([^"]*)"/, remote_match)) {
                                   remote_value = remote_match[1]
                                   remote_found = 1
                               }
                               break
                           }
                           if (next_line ~ /type_string/) {
                               break
                           }
                       }
                       
                       if (remote_found && remote_value != "") {
                           if (!first_entry) {
                               print ","
                           }
                           printf "  {\n"
                           printf "    \"type_string\": \"%s\",\n", type_value
                           printf "    \"remote_source\": \"%s\"\n", remote_value
                           printf "  }"
                           first_entry = 0
                       }
                   }
               }
           }
       }
       END {
           print ""
           print "]"
       }
      ' "${TEMP_DIR}/DETECTION.json.raw" | jq 'map(select(.type_string == "cli" and has("remote_source")))' > "${TEMP_DIR}/DETECTION.json"
  #Compare
   jq -s \
   '
    .[0] as $detection |
    .[1] as $pkg_dump |
    [
      $detection[] |
      select(.type_string == "cli") as $cli_item |
      $pkg_dump[] |
      select(.download == $cli_item.remote_source) |
      . + {"is_cli": "true"}
    ]
   ' "${TEMP_DIR}/DETECTION.json" "${TEMP_DIR}/PKG_DUMP.json" > "${TEMP_DIR}/PKG_DUMP.json.tmp"
  if [[ "$(jq -r '.[] | .source' "${TEMP_DIR}/PKG_DUMP.json.tmp" | grep -Eiv '^null$' | sort -u | wc -l | tr -cd '[:digit:]')" -ge 1000 ]]; then
     cp -fv "${TEMP_DIR}/PKG_DUMP.json.tmp" "${TEMP_DIR}/PKG_DUMP.json"
  else
     echo -e "\n[✗] FATAL: Failed to add CLI Lists\n"
    exit 1
  fi
##Merge with RAW
 jq -s \
  '
   (.[1] | reduce .[] as $item ({}; .[$item.source] = $item)) as $pkg_lookup |
   .[0] | map(select($pkg_lookup[.source]) | . + $pkg_lookup[.source])
  ' "${OUT_DIR}/RAW.json" "${TEMP_DIR}/PKG_DUMP.json" > "${TEMP_DIR}/PKG_DUMP.json.tmp"
  if [[ "$(jq -r '.[] | .source' "${TEMP_DIR}/PKG_DUMP.json.tmp" | grep -Eiv '^null$' | sort -u | wc -l | tr -cd '[:digit:]')" -ge 1000 ]]; then
     cp -fv "${TEMP_DIR}/PKG_DUMP.json.tmp" "${TEMP_DIR}/PKG_DUMP.json"
  else
     echo -e "\n[✗] FATAL: Failed to Merge Final Lists\n"
    exit 1
  fi
##Compute Ranks & Finalize 
 cat "${TEMP_DIR}/PKG_DUMP.json" | jq 'map(. + {"name": (.download | split("@v")[0] | split("/") | .[-2] | ascii_downcase | gsub("[^a-z0-9_.-]"; ""))})' | jq \
   '
    sort_by([
      -(if .stars then (.stars | tonumber) else -1 end),
      .name
    ]) |
    to_entries |
    map(.value + { rank: (.key + 1 | tostring) })
   ' > "${TEMP_DIR}/PKG_DUMP.json.tmp"
 jq 'map(select(.is_cli == "true"))' "${TEMP_DIR}/PKG_DUMP.json.tmp" |\
 jq 'walk(if type == "boolean" or type == "number" then tostring else . end)' |\
 jq 'map(select(
    .name != null and .name != "" and
    .is_cli != null and .is_cli != "" and
    .version != null and .version != ""
 ))' | jq 'unique_by(.source) | sort_by(.rank | tonumber) | [range(length)] as $indices | [., $indices] | transpose | map(.[0] + {rank: (.[1] + 1 | tostring)})' > "${TEMP_DIR}/PKG_DUMP.json"
  if [[ "$(jq -r '.[] | .source' "${TEMP_DIR}/PKG_DUMP.json" | grep -Eiv '^null$' | sort -u | wc -l | tr -cd '[:digit:]')" -ge 1000 ]]; then
     cp -fv "${TEMP_DIR}/PKG_DUMP.json" "${OUT_DIR}/PKG_DUMP.json"
  else
     echo -e "\n[✗] FATAL: Failed to create Final Metadata\n"
    exit 1
  fi
#Print stats
 du -bh "${OUT_DIR}/RAW.json"
 du -bh "${OUT_DIR}/PKG_DUMP.json"
 echo -e "\n[+] Total Packages: $(jq -r '.[] | .source' "${OUT_DIR}/RAW.json" | wc -l)"
 echo -e "[+] Binary Packages: $(jq -r '.[] | .source' "${OUT_DIR}/PKG_DUMP.json" | wc -l)"
 echo -e "[+] Used TEMP dir: ${TEMP_DIR}"
 echo -e "[+] Used OUT dir: ${OUT_DIR}\n"
#Cleanup
popd &>/dev/null
#Copy
PKG_COUNT="$(jq -r '.[] | .name' "${OUT_DIR}/PKG_DUMP.json" | sort -u | wc -l | tr -d '[:space:]')"
if [[ "${PKG_COUNT}" -ge 1000 ]]; then
  if [[ ! -d "${SYSTMP}" ]]; then
    SYSTMP="$(dirname $(mktemp -u))"
  fi
  cp -fv "${OUT_DIR}/RAW.json" "${SYSTMP}/PKG_RAW.json"
  cp -fv "${OUT_DIR}/PKG_DUMP.json" "${SYSTMP}/PKG_DUMP.json"
fi
#-------------------------------------------------------#