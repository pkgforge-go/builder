#!/usr/bin/env bash
## <DO NOT RUN STANDALONE, meant for CI Only>
## Meant to Generate Metadata Json
## Self: https://raw.githubusercontent.com/pkgforge-go/builder/refs/heads/main/scripts/gen_meta.sh
# PARALLEL_LIMIT="20" bash <(curl -qfsSL "https://raw.githubusercontent.com/pkgforge-go/builder/refs/heads/main/scripts/gen_meta.sh")
#-------------------------------------------------------#

#-------------------------------------------------------#
##ENV
export TZ="UTC"
SYSTMP="$(dirname $(mktemp -u))" && export SYSTMP="${SYSTMP}"
TMPDIR="$(mktemp -d)" && export TMPDIR="${TMPDIR}" ; echo -e "\n[+] Using TEMP: ${TMPDIR}\n"
mkdir -pv "${TMPDIR}/assets" "${TMPDIR}/data" "${TMPDIR}/repo" "${TMPDIR}/src" "${TMPDIR}/tmp"
#-------------------------------------------------------#

#-------------------------------------------------------#
pushd "${TMPDIR}" &>/dev/null
#Get Repo Tags
 META_REPO_URL="https://github.com/pkgforge-go/builder.git"
 META_BRANCH="metadata"
 CUTOFF_DATE="$(date --utc -d '7 days ago' '+%Y-%m-%d' | tr -d '[:space:]')" ; unset META_TAGS
 export META_REPO_URL META_BRANCH CUTOFF_DATE
 #Clone
  cd "${TMPDIR}/repo" &&\
    git init --quiet
    git remote add origin "${META_REPO_URL}"
    git fetch --depth="1" origin "${META_BRANCH}"
    git checkout -b "${META_BRANCH}" "FETCH_HEAD"
    git sparse-checkout init --cone
 #Check
   if [[ -d "${TMPDIR}/repo/.git" && "$(du -s "${TMPDIR}/repo" | cut -f1)" -gt 100 ]]; then
     readarray -t REMOTE_DIRS < <(
      git ls-tree --name-only "${META_BRANCH}" |
      xargs -I{} basename "{}" |
      sed -E 's/^[[:space:]]+|[[:space:]]+$//g' |
      grep -Ei '^METADATA-[0-9]{4}_[0-9]{2}_[0-9]{2}$' |
      sort -u
     )
   else
      echo -e "\n[X] FATAL: Failed to setup Repo\n"
      exit 1
   fi
 #Get tags
  META_TAGS=()
   for dir in "${REMOTE_DIRS[@]}"; do
     TAG_DATE="${dir#METADATA-}"
     TAG_D="${TAG_DATE//_/-}"
       if [[ "$(date -d "${TAG_D}" '+%s')" -gt "$(date -d "${CUTOFF_DATE}" '+%s')" ]]; then
         META_TAGS+=("${dir}")
       fi
   done
   #Check
    if [[ -n "${META_TAGS[*]}" && "${#META_TAGS[@]}" -ge 1 ]]; then
      echo -e "\n[+] Total Tags: ${#META_TAGS[@]}"
      echo -e "[+] Tags: ${META_TAGS[*]}"
    else
      echo -e "\n[X] FATAL: Failed to Fetch needed Tags\n"
      echo -e "[+] Tags: ${META_TAGS[*]}"
     exit 1
    fi
 #Fetch
   git sparse-checkout set "${META_TAGS[@]}"
   git fetch --depth="1" origin "${META_BRANCH}"
   for tag in "${META_TAGS[@]}"; do
     export tag
     mkdir -pv "${TMPDIR}/assets/${tag}"
     find "${TMPDIR}/repo/${tag}" -type f -iregex '.*\.json$' -exec bash -c 'jq empty "{}" 2>/dev/null && cp -fv "{}" "${TMPDIR}/assets/${tag}/"' \;
     unset tag
   done
 #Rename Assets
  find "${TMPDIR}/assets/" -mindepth 1 -type f -exec bash -c \
   '
    for file; do
     dir=$(dirname "$file")
     base=$(basename "$dir")
     mv -fv "$file" "${file%.*}_${base}.${file##*.}"
    done
   ' _ {} +
#Copy Valid Assets
 find "${TMPDIR}/assets" -type f -size -3c -delete
 find "${TMPDIR}/assets/" -type f -iregex '.*\.json$' -exec bash -c 'cp -f "{}" ${TMPDIR}/src/' \;
#Copy Newer Assets 
 find "${TMPDIR}/src" -type f -iregex '.*\.json$' | sort -u | awk -F'[_-]' '{base=""; for(i=1;i<=NF-1;i++) base=base (i>1?"_":"") $i; date=$(NF); file[base]=(file[base]==""||date>file[base])?date:file[base]; path[base,date]=$0} END {for(b in file) print path[b,file[b]]}' | xargs -I "{}" cp -fv "{}" "${TMPDIR}/data"
#-------------------------------------------------------#

#-------------------------------------------------------#
##Merge
 HOST_TRIPLETS=("aarch64-Linux" "loongarch64-Linux" "riscv64-Linux" "x86_64-Linux")
 for HOST_TRIPLET in "${HOST_TRIPLETS[@]}"; do
    echo -e "\n[+] Processing ${HOST_TRIPLET}..."
    #Gen Raw
     find "${TMPDIR}/data" -type f -iregex ".*-${HOST_TRIPLET}.*\.json$" -exec \
      bash -c 'jq empty "{}" 2>/dev/null && cat "{}"' \; | \
         jq --arg host "${HOST_TRIPLET}" 'select(.host | ascii_downcase == ($host | ascii_downcase))' | \
         jq -s 'sort_by(.pkg) | unique_by(.ghcr_pkg)' > "${TMPDIR}/${HOST_TRIPLET}.json.tmp"
    #Fixup
     sed -E 's~\bhttps?:/{1,2}\b~https://~g' -i "${TMPDIR}/${HOST_TRIPLET}.json.tmp"
    #Calc Rank & Merge
     jq \
      '
       sort_by([
         -(if .downloads then (.downloads | tonumber) else -1 end),
         .name
       ]) |
       to_entries |
       map(.value + { rank: (.key + 1 | tostring) })
      ' "${TMPDIR}/${HOST_TRIPLET}.json.tmp" | jq '.[] | .download_count |= tostring' | jq \
      'walk(if type == "boolean" or type == "number" then tostring else . end)' | jq -s \
      'if type == "array" then . else [.] end' | jq 'map(to_entries | sort_by(.key) | from_entries)
       ' | jq \
       '
         map(select(
        .pkg != null and .pkg != "" and
        .pkg_id != null and .pkg_id != "" and
        .pkg_name != null and .pkg_name != "" and
        .description != null and .description != "" and
        .ghcr_pkg != null and .ghcr_pkg != "" and
        .version != null and .version != ""
        ))
       ' | jq 'if type == "array" then map(if (.src_url | type) == "string" then .src_url = [.src_url] else . end) else if (.src_url | type) == "string" then .src_url = [.src_url] else . end end' |\
        jq 'unique_by(.ghcr_pkg) | sort_by(.pkg)' > "${TMPDIR}/${HOST_TRIPLET}.json"
    #Sanity Check
     PKG_COUNT="$(jq -r '.[] | .pkg_id' "${TMPDIR}/${HOST_TRIPLET}.json" | grep -iv 'null' | wc -l | tr -d '[:space:]')"
     if [[ "${PKG_COUNT}" -le 5 ]]; then
        echo -e "\n[-] FATAL: Failed to Generate MetaData\n"
        echo "[-] Count: ${PKG_COUNT}"
        continue
     else
        echo -e "\n[+] Packages: ${PKG_COUNT}"
        cp -fv "${TMPDIR}/${HOST_TRIPLET}.json" "${SYSTMP}/${HOST_TRIPLET}.json"
     fi
 done
#-------------------------------------------------------#