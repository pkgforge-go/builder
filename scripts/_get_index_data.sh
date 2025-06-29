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
CUTOFF_DATE="$(date -d 'last week' '+%Y-%m-%d' | tr -d '[:space:]')"
export CUTOFF_DATE SYSTMP
##Cmd
install_tool() {
    sudo curl -qfsSL "$2" -o "/usr/local/bin/$1"
    sudo chmod 'a+x' "/usr/local/bin/$1"
    hash -r &>/dev/null
    command -v "$1" &>/dev/null || { echo -e "\n[-] $1 NOT Found"; exit 1; }
}
install_tool "_detect_if_cli" "https://raw.githubusercontent.com/pkgforge-go/builder/refs/heads/main/scripts/_detect_if_cli.sh"
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
  .[] 
  | select(
      (.source | ascii_downcase | test("^6github\\.com|go-micro\\.|kubevirt\\.|opentelemetry\\.|staging\\.|www\\.") | not)
      and
      (.source | ascii_downcase | endswith(".git") | not)
      and
      (.source | ascii_downcase | contains("bitbucket.org/", "buildroot.net/", "codeberg.org/", "gitee.com/", "github.com/", "gitlab.com/", "sr.ht/", "sourceforge.net/"))
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
  if [[ "$(jq -r '.[] | .source' "${TEMP_DIR}/PKG_DUMP.json" | grep -Eiv '^null$' | sort -u | wc -l | tr -cd '[:digit:]')" -ge 1000 ]]; then
     cp -fv "${TEMP_DIR}/PKG_DUMP.json" "${OUT_DIR}/PKG_DUMP.json"
  else
     echo -e "\n[✗] FATAL: Failed to enrich PKG Data Lists\n"
    exit 1
  fi








##Check if CLI
  #Cleanup
   {
    while true; do
      find "${SYSTMP}" -path "*/_REPO_" -mmin +2 -mmin -10 -exec rm -rf "{}" \; 2>/dev/null
      find "${SYSTMP}" -type d -name "tmp.*" -empty -mmin +2 -mmin -10 -delete 2>/dev/null
      sleep 123
    done
   } &
   CLEANUP_PID=$!
  #Main 
   jq -r '.[] | .download' "${OUT_DIR}/PKG_DUMP.json" | \
    sort -u | xargs -P "${PARALLEL_LIMIT:-$(($(nproc)+1))}" -I "{}" timeout -k 10s 300s \
      bash -c '_detect_if_cli "{}" --quiet --json || sleep "$(shuf -i 1500-4500 -n 1)e-3"' | tee -a "${TEMP_DIR}/DETECTION.json.raw"
    awk '/^\s*{\s*$/{flag=1; buffer="{\n"; next} /^\s*}\s*$/{if(flag){buffer=buffer"}\n"; print buffer}; flag=0; next} flag{buffer=buffer$0"\n"}' "${TEMP_DIR}/DETECTION.json.raw" | jq -c '. as $line | (fromjson? | .message) // $line' >> "${TEMP_DIR}/DETECTION.json.tmp"
    jq -s 'map(select(.type == "cli" and has("url")))' "${TEMP_DIR}/DETECTION.json.tmp" | jq . > "${TEMP_DIR}/DETECTION.json"
    find "${SYSTMP}" -path "*/_REPO_" -exec rm -rf "{}" \; 2>/dev/null
    kill -9 "${CLEANUP_PID}"
  #Compare
   jq -s \
   '
    .[0] as $detection |
    .[1] as $pkg_dump |
    [
      $detection[] |
      select(.type == "cli") as $cli_item |
      $pkg_dump[] |
      select(.download == $cli_item.url) |
      . + {"is_cli": "true"}
    ]
   ' "${TEMP_DIR}/DETECTION.json" "${OUT_DIR}/PKG_DUMP.json" > "${TEMP_DIR}/PKGS_CLI_ONLY.json.tmp"
##Compute Ranks & Finalize 
 cat "${TEMP_DIR}/PKGS_CLI_ONLY.json.tmp" | jq 'map(. + {"name": (.download | split("@v")[0] | split("/") | .[-2] | ascii_downcase | gsub("[^a-z0-9_.-]"; ""))})' | jq \
   '
    sort_by([
      -(if .stars then (.stars | tonumber) else -1 end),
      .name
    ]) |
    to_entries |
    map(.value + { rank: (.key + 1 | tostring) })
   ' > "${TEMP_DIR}/PKGS_CLI_ONLY.json"
 jq 'map(select(.is_cli == "true"))' "${TEMP_DIR}/PKGS_CLI_ONLY.json" |\
 jq 'walk(if type == "boolean" or type == "number" then tostring else . end)' |\
 jq 'map(select(
    .name != null and .name != "" and
    .is_cli != null and .is_cli != "" and
    .version != null and .version != ""
 ))' | jq 'unique_by(.source) | sort_by(.rank | tonumber) | [range(length)] as $indices | [., $indices] | transpose | map(.[0] + {rank: (.[1] + 1 | tostring)})' > "${OUT_DIR}/PKGS_CLI_ONLY.json"
#Print stats
 du -bh "${OUT_DIR}/PKG_DUMP.json"
 du -bh "${OUT_DIR}/PKGS_CLI_ONLY.json"
 echo -e "\n[+] Total Packages: $(jq -r '.[] | .source' "${OUT_DIR}/PKG_DUMP.json" | wc -l)"
 echo -e "[+] Binary Packages: $(jq -r '.[] | .source' "${OUT_DIR}/PKGS_CLI_ONLY.json" | wc -l)"
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
  cp -fv "${OUT_DIR}/PKG_DUMP.json" "${SYSTMP}/PKG_DUMP.json"
  cp -fv "${OUT_DIR}/PKGS_CLI_ONLY.json" "${SYSTMP}/PKGS_CLI_ONLY.json"
fi
#-------------------------------------------------------#