#!/usr/bin/env bash

#VERSION=0.0.1
#Barebones, will not be improved, meant for one time usage
#slow on purpose to avoid rate limits, 10,000 packages take ~ 2 hrs to process.

#-------------------------------------------------------#
##Env
pushd "$(mktemp -d)" &>/dev/null
if [[ ! -d "${SYSTMP}" ]]; then
 SYSTMP="$(dirname $(mktemp -u))"
fi
export SYSTMP
export TEMP_DIR="$(realpath .)"
export OUT_DIR="/tmp/pkgs"
rm -rf "${OUT_DIR}" 2>/dev/null ; mkdir -p "${OUT_DIR}/TEMP" "${TEMP_DIR}/tmp"
echo -e "\n[+] Using TEMP dir: ${TEMP_DIR}"
echo -e "[+] Using OUT dir: ${OUT_DIR}\n"
##Cmd
install_tool() {
    sudo curl -qfsSL "$2" -o "/usr/local/bin/$1"
    sudo chmod 'a+x' "/usr/local/bin/$1"
    hash -r &>/dev/null
    command -v "$1" &>/dev/null || { echo -e "\n[-] $1 NOT Found"; exit 1; }
}
install_tool "_detect_if_cli" "https://raw.githubusercontent.com/pkgforge-go/builder/refs/heads/main/scripts/_detect_if_cli.sh"
#install_tool "extraxtor" "https://github.com/pkgforge/devscripts/raw/refs/heads/main/Linux/extraxtor.sh"
install_tool "extraxtor" "https://bin.pkgforge.dev/$(uname -m)-$(uname -s)/extraxtor"
##Token
if [[ -n ${GITHUB_TOKEN+x} && -n ${GITHUB_TOKEN//[[:space:]]/} ]]; then
   :
else
    echo -e "\n[✗] FATAL: RO GITHUB_TOKEN is Needed\n"
   exit 1
fi
#-------------------------------------------------------#

#-------------------------------------------------------#
##Fetch
#Get Starred Repos (Azathothas/Stars)
 GH_USERS=("Azathothas" "xplshn")
 for GH_USER in "${GH_USERS[@]}"; do
   echo -e "\n[+] Scraping Starred Repos (https://github.com/${GH_USER}?tab=stars)\n"
   RAW_OUT_FILE="${TEMP_DIR}/tmp/${GH_USER}_STARRED.json"
   for i in {1..5}; do
    gh api "/users/${GH_USER}/starred" --paginate 2>/dev/null |& cat - > "${RAW_OUT_FILE}"
    if [[ $(stat -c%s "${RAW_OUT_FILE}" | tr -d '[:space:]') -lt 10000 ]]; then
      echo "Retrying... ${i}/5"
      sleep 2
    elif [[ $(stat -c%s "${RAW_OUT_FILE}" | tr -d '[:space:]') -gt 10000 ]]; then
      break
    fi
   done
 done
#Get from search
 T_CUTOFF_DATE="$(date -d '1 year ago' '+%Y-%m-%d')"
 T_QUERY="language:go stars:>=5 pushed:>${T_CUTOFF_DATE}"
 T_ENCODED_QUERY="$(printf '%s' "$T_QUERY" | jq -sRr @uri)"
 echo -e "\n[+] Scraping Search API\n"
 for i in {1..2}; do
  gh api "/search/repositories?q=${T_ENCODED_QUERY}&sort=updated&order=desc&per_page=100" --paginate 2>/dev/null |& cat - >"${TEMP_DIR}/tmp/SEARCH.json"
    if [[ $(stat -c%s "${TEMP_DIR}/tmp/SEARCH.json" | tr -d '[:space:]') -lt 10000 ]]; then
      echo "Retrying... ${i}/5"
      sleep 2
    elif [[ $(stat -c%s "${TEMP_DIR}/tmp/SEARCH.json" | tr -d '[:space:]') -gt 10000 ]]; then
      break
    fi
 done
#Get List (https://github.com/avelino/awesome-go)
 curl -qfsSL "https://github.com/avelino/awesome-go/raw/refs/heads/main/README.md" | \
   grep -oE 'https://github\.com/[^[:space:])]+' | \
   grep -vE '(/blob/|/wiki/|\.md|\.rst)' | \
   sed 's/[.,;:!?]*$//' | \
   sort -u -o "${TEMP_DIR}/tmp/REPOS.txt"
#Get List (https://github.com/pkgforge-go/builder/blob/main/data/_IN.txt)
 curl -qfsSL "https://github.com/pkgforge-go/builder/raw/refs/heads/main/data/_IN.txt" | \
   grep -oE 'https://github\.com/[^[:space:])]+' | \
   grep -vE '(/blob/|/wiki/|\.md|\.rst)' | \
   sed 's/[.,;:!?]*$//' | \
   sort -u >> "${TEMP_DIR}/tmp/REPOS.txt"
#Sort & Cleanup List
 sort -u "${TEMP_DIR}/tmp/REPOS.txt" -o "${TEMP_DIR}/tmp/REPOS.txt"
 sed -E 's/^[[:space:]]+|[[:space:]]+$//g' -i "${TEMP_DIR}/tmp/REPOS.txt"
 sed '/^[[:space:]]*$/d' -i "${TEMP_DIR}/tmp/REPOS.txt"
 if [[ "$(wc -l < "${TEMP_DIR}/tmp/REPOS.txt")" -ge 1000 ]]; then
   #Gen
    mapfile -t "REPO_URLS" < "${TEMP_DIR}/tmp/REPOS.txt"
    T_OUT="${TEMP_DIR}/tmp/REPOS.json"
    > "${T_OUT}" ; find "${OUT_DIR}/TEMP" -type f -iname "*.json" -delete
    TOTAL=${#REPO_URLS[@]}
    i=0
    echo -e "\n[+] Fetching Repo Data\n"
    for ((j=0; j<${#REPO_URLS[@]}; j+=10)); do
      batch=("${REPO_URLS[@]:j:10}")
      for REPO_URL in "${batch[@]}"; do
       ((i++))
        if [[ $REPO_URL =~ https://github\.com/([^/]+/[^/]+) ]]; then
         REPO_PATH="$(echo ${REPO_URL} | sed -E 's|^(https://github.com/)?([^/]+/[^/]+).*|\2|' | tr -d '[:space:]')"
         TEMP_OUT="${OUT_DIR}/TEMP/${i}-$(date --utc "+%y%m%dT%H%M%S$(date +%3N)").json"
         echo "https://github.com/${REPO_PATH} ==> ${TEMP_OUT} [${i}/${TOTAL}]"
         {
             RESPONSE="$(curl -qfsSL "https://api.gh.pkgforge.dev/repos/${REPO_PATH}")"
             if echo "$RESPONSE" | jq empty 2>/dev/null; then
                 echo "$RESPONSE" | jq -c . >> "${TEMP_OUT}"
             fi
         } &
        fi
      done
     wait &>/dev/null
    done
   #Merge
    find "${OUT_DIR}/TEMP" -type f -iname "*.json" -size -3c -delete
    find "${OUT_DIR}/TEMP" -type f -iname "*.json" -exec cat "{}" + > "${T_OUT}"
 else
    echo -e "\n[✗] FATAL: Failed to fetch Repo Lists\n"
   #exit 1
 fi
#Parse
 find "${TEMP_DIR}" -type f -iname "*.json" -size -3c -delete
 find "${TEMP_DIR}/tmp" -type f -iname "*_STARRED.json" -exec jq -c '.[]' "{}" + | sed '/^\s*[\[{]/!d' > "${TEMP_DIR}/RAW.json.tmp"
 find "${TEMP_DIR}/tmp" -type f -iname "*SEARCH.json" -exec jq -c '.[]' "{}" + | sed '/^\s*[\[{]/!d' >> "${TEMP_DIR}/RAW.json.tmp"
 [[ -s "${T_OUT}" ]] && cat "${T_OUT}" | sed '/^\s*[\[{]/!d' >> "${TEMP_DIR}/RAW.json.tmp"
#Map
 jq -s \
 '
  if length == 1 and .[0] | type == "array" then
    .[0]
  else
    .
  end
  | flatten
  | map(select(type == "object" and has("name")))
  | unique_by(.html_url | ascii_downcase)
  | sort_by(.name | ascii_downcase)
 ' "${TEMP_DIR}/RAW.json.tmp" | jq \
 '
  def sanitize: if type == "string" then gsub("[`${}\\\\\"'\''();|&<>]"; "_") else . end;
  [ .[]
    | select(
        (.language // "" | ascii_downcase) == "go"
        or (.language // "" | ascii_downcase) == "golang"
        or ((.topics // []) | map(ascii_downcase) | any(. == "golang" or . == "go-lang"))
      )
    | {
        branch: (.default_branch // ""),
        clone: (.clone_url // ""),
        description: (.description // "" | sanitize),
        homepage: (.html_url // ""),
        license: [(.license.spdx_id // "") | select(. != "")],
        name: (.name // "" | sanitize),
        pkg_id: ((.html_url // "") | sub("^https?://"; "") | gsub("[^a-zA-Z0-9.-]"; "_")) | sanitize,
        repo_name: (.full_name // "" | sanitize),
        stars: (.stargazers_count // 0),
        tag: (.topics // [] | map(sanitize)),
        updated_at: (.updated_at // "")
      }
  ]
 ' | jq 'unique_by(.pkg_id) | sort_by(.name)' > "${OUT_DIR}/REPO_INPUT.json.tmp"
#Filter 
 CUTOFF_DATE="$(date -d 'last year' '+%Y-01-01' | tr -d '[:space:]')"
 jq --arg cutoff_date "${CUTOFF_DATE}" '[.[] | select((.updated_at | split("T")[0] | strptime("%Y-%m-%d") | mktime) >= ($cutoff_date | strptime("%Y-%m-%d") | mktime))]' "${OUT_DIR}/REPO_INPUT.json.tmp" > "${OUT_DIR}/REPO_INPUT.json"
#Copy
 PKG_COUNT="$(jq -r '.[] | .name' "${OUT_DIR}/REPO_INPUT.json" | grep -iv '^null$' | sort -u | wc -l | tr -d '[:space:]')"
 if [[ "${PKG_COUNT}" -ge 1000 ]]; then
    cp -fv "${OUT_DIR}/REPO_INPUT.json" "${OUT_DIR}/REPO_DUMP.json"
    cp -fv "${OUT_DIR}/REPO_DUMP.json" "${SYSTMP}/REPO_DUMP.json"
 else
    echo -e "\n[✗] FATAL: Failed to generate Repo Input\n"
   exit 1
 fi
 unset PKG_COUNT
 #Check for CLI
 echo -e "\n[+] Filtering Packages for CLI...\n"
  #Cleanup Func
   {
    while true; do
      find "${SYSTMP}" -path "*/_REPO_" -mmin +2 -mmin -10 -exec rm -rf "{}" \; 2>/dev/null
      find "${SYSTMP}" -type d -name "tmp.*" -empty -mmin +2 -mmin -10 -delete 2>/dev/null
      sleep 123
    done
   } &
   CLEANUP_PID=$!
  #Main  
   jq -r '.[] | .clone' "${OUT_DIR}/REPO_DUMP.json" | \
     sed 's/\.git\([[:space:]]*\|$\)/\/archive\/HEAD.tar.gz\1/g' | \
     sort -u | xargs -P "${PARALLEL_LIMIT:-$(($(nproc)+1))}" -I "{}" timeout -k 10s 300s \
       bash -c '_detect_if_cli "{}" --quiet --json || sleep "$(shuf -i 1500-4500 -n 1)e-3"' | tee -a "${TEMP_DIR}/DETECTION.json.raw"
   awk '/^\s*{\s*$/{flag=1; buffer="{\n"; next} /^\s*}\s*$/{if(flag){buffer=buffer"}\n"; print buffer}; flag=0; next} flag{buffer=buffer$0"\n"}' "${TEMP_DIR}/DETECTION.json.raw" | jq -c '. as $line | (fromjson? | .message) // $line' >> "${TEMP_DIR}/DETECTION.json.tmp"
   jq -s 'map(select(.type == "cli" and has("url")))' "${TEMP_DIR}/DETECTION.json.tmp" | jq . > "${TEMP_DIR}/DETECTION.json"
 #Copy
 PKG_COUNT="$(jq -r '.[] | .url' "${TEMP_DIR}/DETECTION.json" | grep -iv '^null$' | sort -u | wc -l | tr -d '[:space:]')"
 if [[ "${PKG_COUNT}" -ge 100 ]]; then
    cp -fv "${TEMP_DIR}/DETECTION.json" "${OUT_DIR}/DETECTION.json"
 else
    echo -e "\n[✗] FATAL: Failed to Check for CLI\n"
   exit 1
 fi
 find "${SYSTMP}" -path "*/_REPO_" -exec rm -rf "{}" \; 2>/dev/null
 kill -9 "${CLEANUP_PID}"
 unset PKG_COUNT
#-------------------------------------------------------#

#-------------------------------------------------------#
##Process
 echo -e "\n[+] Processing Repos [$(jq -r '.[] | .name' "${TEMP_DIR}/DETECTION.json" | wc -l)] ...\n"
 find "${OUT_DIR}/TEMP" -type f -iname "*.json" -delete
 process_repo() {
     #Env
     local input="$1"
     if [[ "$input" == *"tar.gz"* ]] || [[ "$input" == *".zip"* ]]; then
       repo="$(echo "${input}" | sed 's|/archive/HEAD\.zip$|.git|g; s|/archive/HEAD\.tar\.gz$|.git|g')"
       local repo="$(echo "${repo}" | tr -d '"'\''[:space:]')"
     elif [[ "$input" == *".git" ]]; then
       local repo="$(echo "${input}" | tr -d '"'\''[:space:]')"
     fi
     local safe_repo="$(echo "${repo}" | sed -E 's|https://github.com/([^/]+/[^.]+)\.git|\1|' | sed -E 's|[^a-zA-Z0-9_]|_|g')"
     local retries=0
     local max_retries=2
     local is_cli="true"
     local commit=""
     local version_upstream=""
     local version=""
     local version_tmp=""
     #Check
     while [ $retries -le $max_retries ]; do
         #Clone repo
           pushd "$(mktemp -d)" &>/dev/null && \
           git clone --depth="1" --filter="blob:none" --no-checkout --single-branch --quiet "${repo}" "./TEMPREPO" &>/dev/null
           if [[ -d "./TEMPREPO/.git" ]]; then
             commit="$(git --git-dir="./TEMPREPO/.git" --no-pager log -1 --pretty=format:'%H' | tr -d '"'\''[:space:]')"
             version_upstream="$(git --git-dir="./TEMPREPO/.git" --no-pager describe --tags --abbrev="0" 2>/dev/null)"
             version="$(git --git-dir="./TEMPREPO/.git" --no-pager log -1 --pretty=format:'HEAD-%h-%cd' --date=format:'%y%m%dT%H%M%S' | tr -d '"'\''[:space:]')"
             is_cli="true"
             rm -rf "$(realpath .)" &>/dev/null ; popd &>/dev/null
           else
             popd &>/dev/null
             continue
           fi
         #Cleanup
          find "${SYSTMP}" -path "*/repo" -exec rm -rf "{}" \; 2>/dev/null
         #Retries
          ((retries++))
          [ $retries -le $max_retries ] && sleep 1
     done
     #Add new fields
     if [[ "${is_cli}" == "true" ]]; then
       jq --arg repo "${repo}" --arg is_cli "${is_cli}" \
          --arg commit "${commit}" --arg version_upstream "${version_upstream}" --arg version "${version}" \
         '.[] | select(.clone == $repo) | . + {is_cli: ($is_cli == "true"), commit: $commit, version: $version, version_upstream: $version_upstream}' \
         "${OUT_DIR}/REPO_DUMP.json" > "${OUT_DIR}/TEMP/${safe_repo}.json"
       echo -e "Processed: $repo (is_cli: $is_cli) (version: $version) [${OUT_DIR}/TEMP/${safe_repo}.json]"
     else
       echo -e "Skipped: $repo (is_cli: $is_cli)"
     fi
 }
 export -f process_repo
 #too many will ratelimit us
 jq -r '.[] | .url' "${OUT_DIR}/DETECTION.json" | \
   sed 's|/archive/HEAD\.zip$|.git|g; s|/archive/HEAD\.tar\.gz$|.git|g' | \
   sort -u | \
   xargs -n 1 -P "${PARALLEL_LIMIT:-$(($(nproc)+1))}" \
    bash -c 'process_repo "$0" || sleep "$(shuf -i 1500-4500 -n 1)e-3"'
#Merge Again
 find "${OUT_DIR}/TEMP" -type f -size -3c -delete
 find "${OUT_DIR}/TEMP" -type f -iname "*.json" -exec cat "{}" + > "${OUT_DIR}/RAW.json.tmp"
 awk '/^\s*{\s*$/{flag=1; buffer="{\n"; next} /^\s*}\s*$/{if(flag){buffer=buffer"}\n"; print buffer}; flag=0; next} flag{buffer=buffer$0"\n"}' "${OUT_DIR}/RAW.json.tmp" | jq -c '. as $line | (fromjson? | .message) // $line' >> "${OUT_DIR}/RAW.json.raw"
 jq -s '[.[] | select(type == "object" and has("name"))] | unique_by(.pkg_id | ascii_downcase) | sort_by(.name | ascii_downcase) | walk(if type == "object" then with_entries(select(.value != null and .value != "" and .value != "null")) elif type == "boolean" or type == "number" then tostring else . end) | map(to_entries | sort_by(.key) | from_entries)' \
 "${OUT_DIR}/RAW.json.raw" | jq \
 '
  sort_by([
    -(if .stars then (.stars | tonumber) else -1 end),
    .name
  ]) |
  to_entries |
  map(.value + { rank: (.key + 1 | tostring) })
 ' > "${TEMP_DIR}/PKGS_CLI_ONLY.json"
#Compute Ranks & Finalize
 jq 'map(select(.is_cli == "true"))' "${TEMP_DIR}/PKGS_CLI_ONLY.json" |\
 jq 'walk(if type == "boolean" or type == "number" then tostring else . end)' |\
 jq 'map(select(
    .name != null and .name != "" and
    .is_cli != null and .is_cli != "" and
    .version != null and .version != ""
 ))' | jq 'unique_by(.pkg_id) | sort_by(.rank | tonumber) | [range(length)] as $indices | [., $indices] | transpose | map(.[0] + {rank: (.[1] + 1 | tostring)})' > "${OUT_DIR}/PKGS_CLI_ONLY.json"
#Print stats
 du -bh "${OUT_DIR}/REPO_DUMP.json"
 du -bh "${OUT_DIR}/PKGS_CLI_ONLY.json"
 echo -e "\n[+] Total Packages: $(jq -r '.[] | .name' "${OUT_DIR}/REPO_DUMP.json" | wc -l)"
 echo -e "[+] Binary Packages: $(jq -r '.[] | .name' "${OUT_DIR}/PKGS_CLI_ONLY.json" | wc -l)"
 echo -e "[+] Used TEMP dir: ${TEMP_DIR}"
 echo -e "[+] Used OUT dir: ${OUT_DIR}\n"
#Cleanup
popd &>/dev/null
#Copy
PKG_COUNT="$(jq -r '.[] | .name' "${OUT_DIR}/REPO_DUMP.json" | sort -u | wc -l | tr -d '[:space:]')"
if [[ "${PKG_COUNT}" -ge 1000 ]]; then
  if [[ ! -d "${SYSTMP}" ]]; then
    SYSTMP="$(dirname $(mktemp -u))"
  fi
  cp -fv "${OUT_DIR}/REPO_DUMP.json" "${SYSTMP}/REPO_DUMP.json"
  cp -fv "${OUT_DIR}/PKGS_CLI_ONLY.json" "${SYSTMP}/PKGS_CLI_ONLY.json"
fi
#-------------------------------------------------------#