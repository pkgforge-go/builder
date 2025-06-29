#!/usr/bin/env bash
## <DO NOT RUN STANDALONE, meant for CI Only>
## Meant to Build Go Packages using Zig
## Self: https://raw.githubusercontent.com/pkgforge-go/builder/refs/heads/main/scripts/builder.sh
# bash <(curl -qfsSL "https://raw.githubusercontent.com/pkgforge-go/builder/refs/heads/main/scripts/builder.sh")
#-------------------------------------------------------#

#-------------------------------------------------------#
##Version
GB_VERSION="0.0.4" && echo -e "[+] Go Builder Version: ${GB_VERSION}" ; unset GB_VERSION
##Enable Debug
 if [[ "${DEBUG}" = "1" ]] || [[ "${DEBUG}" = "ON" ]]; then
    set -x
 fi
#-------------------------------------------------------#

#-------------------------------------------------------#
##Sanity
 build_fail_gh()
 {
  echo "GHA_BUILD_FAILED=YES" >> "${GITHUB_ENV}"
  echo "BUILD_SUCCESSFUL=NO" >> "${GITHUB_ENV}"
 }
 export -f build_fail_gh
#User 
 if [[ -z "${USER+x}" ]] || [[ -z "${USER##*[[:space:]]}" ]]; then
  USER="$(whoami | tr -d '[:space:]')"
 fi
#Home 
 if [[ -z "${HOME+x}" ]] || [[ -z "${HOME##*[[:space:]]}" ]]; then
  HOME="$(getent passwd "${USER}" | awk -F':' 'NF >= 6 {print $6}' | tr -d '[:space:]')"
 fi
#Tz
 export TZ="UTC"
#GH
 if [[ "${GHA_MODE}" != "MATRIX" ]]; then
   echo -e "[-] FATAL: This Script only Works on Github Actions\n"
   build_fail_gh
  exit 1
 fi
#Input
 if [[ -z "${GPKG_NAME+x}" ]]; then
   echo -e "[-] FATAL: Package Name '\${GPKG_NAME}' is NOT Set\n"
   build_fail_gh
  exit 1
 else
   export GPKG_NAME="${GPKG_NAME}"
 fi
 if [[ -z "${GPKG_SRCURL+x}" ]]; then
   echo -e "[-] FATAL: Source URL '\${GPKG_SRCURL}' is NOT Set\n"
   build_fail_gh
  exit 1
 else
   export GPKG_SRCURL="${GPKG_SRCURL}"
 fi
#Target
 if [[ -z "${GO_TARGET+x}" ]]; then
   echo -e "[-] FATAL: Build Target '\${GO_TARGET}' is NOT Set\n"
   build_fail_gh
  exit 1
 else
   export GO_TARGET="${GO_TARGET}"
 fi
#Host
 if [[ -z "${HOST_TRIPLET+x}" ]]; then
  #HOST_TRIPLET="$(uname -m)-$(uname -s)"
  if echo "${GO_TARGET}" | grep -qiE "arm64"; then
   HOST_TRIPLET="aarch64-Linux"
  elif echo "${GO_TARGET}" | grep -qiE "loong64"; then
   HOST_TRIPLET="loongarch64-Linux"
  elif echo "${GO_TARGET}" | grep -qiE "riscv64"; then
   HOST_TRIPLET="riscv64-Linux"
  elif echo "${GO_TARGET}" | grep -qiE "amd64"; then
   HOST_TRIPLET="x86_64-Linux"
  fi
 fi
  HOST_TRIPLET_L="${HOST_TRIPLET,,}"
  export HOST_TRIPLET HOST_TRIPLET_L
#Repo
 export PKG_REPO="builder"
#Tmp
 if [[ ! -d "${SYSTMP}" ]]; then
  SYSTMP="$(dirname $(mktemp -u))" && export SYSTMP
 fi
#User-Agent
 if [[ -z "${USER_AGENT+x}" ]]; then
  USER_AGENT="$(curl -qfsSL 'https://pub.ajam.dev/repos/Azathothas/Wordlists/Misc/User-Agents/ua_chrome_macos_latest.txt')"
 fi
#Path
 export PATH="${HOME}/bin:${HOME}/.cargo/bin:${HOME}/.cargo/env:${HOME}/.go/bin:${HOME}/go/bin:${HOME}/.local/bin:${HOME}/miniconda3/bin:${HOME}/miniconda3/condabin:/usr/local/zig:/usr/local/zig/lib:/usr/local/zig/lib/include:/usr/local/musl/bin:/usr/local/musl/lib:/usr/local/musl/include:${PATH}"
 PATH="$(echo "${PATH}" | awk 'BEGIN{RS=":";ORS=":"}{gsub(/\n/,"");if(!a[$0]++)print}' | sed 's/:*$//')" ; export PATH
 hash -r &>/dev/null
#Install Golang
 bash <(curl -qfsSL "https://raw.githubusercontent.com/pkgforge/devscripts/refs/heads/main/Linux/install_golang.sh")
 hash -r &>/dev/null
 if ! command -v go &> /dev/null; then
   echo -e "\n[-] go NOT Found\n"
   build_fail_gh
  exit 1
 else
  go version
  go env
 fi
#Install Zig
 bash <(curl -qfsSL "https://raw.githubusercontent.com/pkgforge/devscripts/refs/heads/main/Linux/install_zig.sh")
 hash -r &>/dev/null
 if ! command -v zig &> /dev/null; then
   echo -e "\n[-] zig NOT Found\n"
   build_fail_gh
  exit 1
 else
  zig version
  zig env
  #zig targets 2>/dev/null | awk 'BEGIN{i=0}/\.libc.*[=:].*\{/{i=1;next}i&&/^[ \t]*\}/{i=0;next}i&&/^[ \t]*"[^"]*"/{gsub(/^[ \t]*"/,"");gsub(/",?[ \t]*$/,"");if(length($0)>0)print}' | grep -i "${HOST_TRIPLET}"
 fi
 ##Check Needed CMDs
 for DEP_CMD in _detect_if_cli go oras ts zig zstd; do
    case "$(command -v "${DEP_CMD}" 2>/dev/null)" in
        "") echo -e "\n[✗] FATAL: ${DEP_CMD} is NOT INSTALLED\n"
           build_fail_gh
           exit 1 ;;
    esac
 done
#Cleanup
 unset BUILD_DIR GH_TOKEN GITHUB_TOKEN HF_TOKEN
#Dirs
 BUILD_DIR="$(mktemp -d --tmpdir=${SYSTMP} XXXXXXXXXXXXXXXXXX)"
 mkdir -p "${BUILD_DIR}"
 if [[ ! -d "${BUILD_DIR}" ]]; then
    echo -e "\n[✗] FATAL: \${BUILD_DIR} couldn't be created\n"
    build_fail_gh
   exit 1
 else
    export BUILD_DIR
    export G_ARTIFACT_DIR="${BUILD_DIR}/BUILD_ARTIFACTS/${HOST_TRIPLET}" ; mkdir -p "${G_ARTIFACT_DIR}"
    if [[ ! -d "${G_ARTIFACT_DIR}" ]]; then
      echo -e "\n[✗] FATAL: \${G_ARTIFACT_DIR} couldn't be created\n"
      build_fail_gh
     exit 1 
    fi
    mkdir -p "${BUILD_DIR}/BUILD_GPKG"
    mkdir -p "${BUILD_DIR}/BUILD_TMP"
 fi
 [[ "${GHA_MODE}" == "MATRIX" ]] && echo "BUILD_DIR=${BUILD_DIR}" >> "${GITHUB_ENV}"
 [[ "${GHA_MODE}" == "MATRIX" ]] && echo "G_ARTIFACT_DIR=${G_ARTIFACT_DIR}" >> "${GITHUB_ENV}"
#-------------------------------------------------------#

#-------------------------------------------------------#
##Functions
 #Presetup
  presetup_go()
  {
   #Cleanup
    go clean -x -cache -modcache -testcache -fuzzcache
    rm -rvf "./go.sum" "./go.work" "./go.work.sum" 2>/dev/null
   #Init mod
    if [[ ! -f "./go.mod" ]]; then
      go mod init "${PKG_REPO}/${GPKG_NAME}"
    fi
   #Tidy
    go mod tidy -v 
   #Generate
    go generate ./...
  }
  export -f presetup_go
 #Set Build Env
  set_goflags()
  {
   #Host Based ENV 
    if [[ -z "${HOST_TRIPLET:-}" ]]; then
      echo "Error: HOST_TRIPLET is not set or is empty" >&2
      return 1
    elif [[ "${HOST_TRIPLET}" == "aarch64-Linux" ]]; then
      GOOS="linux"
      GOARCH="arm64"
      CC="zig cc -target aarch64-linux-musl"
      CXX="zig c++ -target aarch64-linux-musl"
    elif [[ "${HOST_TRIPLET}" == "loongarch64-Linux" ]]; then
      GOOS="linux"
      GOARCH="loong64"
      CC="zig cc -target loongarch64-linux-musl"
      CXX="zig c++ -target loongarch64-linux-musl"
    elif [[ "${HOST_TRIPLET}" == "riscv64-Linux" ]]; then
      GOOS="linux"
      GOARCH="riscv64"
      CC="zig cc -target riscv64-linux-musl"
      CXX="zig c++ -target riscv64-linux-musl"
    elif [[ "${HOST_TRIPLET}" == "x86_64-Linux" ]]; then
      GOOS="linux"
      GOARCH="amd64"
      CC="zig cc -target x86_64-linux-musl"
      CXX="zig c++ -target x86_64-linux-musl"
    fi
   #Global ENV
    CGO_ENABLED="1"
    CGO_CFLAGS="-O2 -flto=auto -fPIE -fpie -static -w -pipe"
    GPKG_LDFLAGS="-s -w -buildid= -linkmode=external"
    GPKG_EXTLDFLAGS="-s -w -static-pie -Wl,--build-id=none"
    GPKG_TAGS="netgo,osusergo"
    #ZIG_VERBOSE_CC="1"
    #ZIG_VERBOSE_LINK="1"
   #Export
    export CC CGO_CFLAGS CGO_ENABLED CXX GOARCH GOOS GPKG_LDFLAGS GPKG_EXTLDFLAGS GPKG_TAGS ZIG_VERBOSE_CC ZIG_VERBOSE_LINK
   #printenv
    echo -e "\n[+] Build ENV: \n$(go version)"
    go env  
    echo -e "Zig: $(zig version)\n" 
    echo "==> CC: ${CC}"
    echo "==> CGO_CFLAGS: ${CGO_CFLAGS}"
    echo "==> CGO_ENABLED: ${CGO_ENABLED}"
    echo "==> CXX: ${CXX}"
    echo "==> GOARCH: ${GOARCH}"
    echo "==> GOOS: ${GOOS}"
    echo "==> LDFLAGS: ${GPKG_LDFLAGS}"
    echo "==> EXT_LDFLAGS: ${GPKG_EXTLDFLAGS}"
    echo "==> GO_TAGS: ${GPKG_TAGS}"
    echo -e "\n"
  }
  export -f set_goflags
 #Set Build Flags
  go_build()
  {
   #Env  
    echo -e "\n[+] Target: ${GO_TARGET}\n"
    mkdir -p "${G_ARTIFACT_DIR}"
   #Get Cmds
    mapfile -t "GO_CMD_DIRS" < <(go list -f '{{if eq .Name "main"}}{{.Dir}}{{end}}' ./... 2>/dev/null |\
     awk -v pwd="$(pwd)" '
     /^[ \t]*$/ { next }
     {
         gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "")  # Trim whitespace
         if ($0 == pwd) print "./"
         else if (index($0, pwd "/") == 1) print "./" substr($0, length(pwd) + 2)
         else print $0
     }')
     if [[ ${#GO_CMD_DIRS[@]} -le 0 ]]; then
        echo -e "\n[✗] FATAL: Failed to find any CMD Dirs\n" >&2
        build_fail_gh
       return 1
     fi
   #Build
    echo -e "\n[+] Commands: ${GO_CMD_DIRS[*]}\n"
    for GO_CMD_DIR in "${GO_CMD_DIRS[@]}"; do
     if [[ -d "$(realpath ${GO_CMD_DIR})" ]]; then
       GPKG_OWD="$(realpath .)"
       if [[ ${#GO_CMD_DIRS[@]} -eq 1 ]]; then
         GPKG_OUT_T="${G_ARTIFACT_DIR}/${GPKG_NAME_L}"
       elif echo "${GO_CMD_DIR}" | grep -qE "^\./(api|bin|build|builds|ci|circle|cli|cmd|config|configs|doc|docs|example|examples|git|githooks|github|init|internal|main|pkg|service|src|tool|tools|web)?$"; then
         GPKG_OUT_T="${G_ARTIFACT_DIR}/${GPKG_NAME_L}-$(basename "${GO_CMD_DIR}" | tr '[:upper:]' '[:lower:]')"
       else
         GPKG_OUT_T="${G_ARTIFACT_DIR}/$(basename "${GO_CMD_DIR}" | tr '[:upper:]' '[:lower:]')"
       fi
       GPKG_OUT="$(echo "${GPKG_OUT_T}" | sed 's/[-\.[:space:]]*$//' | tr -d '"'\''[:space:]')"
       cd "${GO_CMD_DIR}" || return 1
        echo -e "\n[#] Compiling: ${GO_CMD_DIR} ==> ${GPKG_OUT}\n"
        go build -a -v -x -trimpath \
         -buildmode="pie" \
         -buildvcs="false" \
         -ldflags="${GPKG_LDFLAGS} -extldflags '${GPKG_EXTLDFLAGS}'" \
         -tags="${GPKG_TAGS}" \
         -o "${GPKG_OUT}"
       cd "${GPKG_OWD}" || return 1
       unset GPKG_OUT GPKG_OUT_T GPKG_OWD
     else
        echo -e "\n[✗] FATAL: Failed to find ${GO_CMD_DIR}\n" >&2
        continue
     fi
    done
   #License
    ( askalono --format "json" crawl --follow "$(realpath .)" | jq -r ".. | objects | .path? // empty" | head -n 1 | xargs -I "{}" cp -fv "{}" "${G_ARTIFACT_DIR}/LICENSE" ) 2>/dev/null
   #List
    find "${G_ARTIFACT_DIR}/" -type f -exec bash -c "echo && realpath {} && readelf --section-headers {} 2>/dev/null" \;
    file "${G_ARTIFACT_DIR}/"* && stat -c "%n:         %s Bytes" "${G_ARTIFACT_DIR}/"* && \
    du "${G_ARTIFACT_DIR}/"* --bytes --human-readable --time --time-style="full-iso" --summarize
   #Pretty Print
    echo -e "\n" ; tree "${BUILD_DIR}" 2>/dev/null
    find "${G_ARTIFACT_DIR}" -type f -exec touch "{}" \;
    find "${G_ARTIFACT_DIR}" -maxdepth 1 -type f -print | sort -u | xargs -I "{}" sh -c 'printf "\nFile: $(basename {})\n  Type: $(file -b {})\n  B3sum: $(b3sum {} | cut -d" " -f1)\n  SHA256sum: $(sha256sum {} | cut -d" " -f1)\n  Size: $(du -bh {} | cut -f1)\n"'
   #Checksums
    echo -e "\n[+] Generating (b3sum) Checksums ==> [${G_ARTIFACT_DIR}/CHECKSUM]"
    find "${G_ARTIFACT_DIR}" -maxdepth 1 -type f ! -iname "*CHECKSUM*" -exec b3sum "{}" + | awk '{gsub(".*/", "", $2); print $2 ":" $1}' | tee "${G_ARTIFACT_DIR}/CHECKSUM"
  }
  export -f go_build
#-------------------------------------------------------#

#-------------------------------------------------------#
##Main
   pushd "${BUILD_DIR}" &>/dev/null
  #Download & Extract Pkg
   if [[ "${GPKG_SRCURL}" =~ \.(tar\.gz|tgz|zip)$ ]] ||\
      [[ "${GPKG_SRCURL}" =~ /tarball/ ]] ||\
      [[ "${GPKG_SRCURL}" =~ /zipball/ ]] ||\
      [[ "${GPKG_SRCURL}" =~ /archive/ ]]; then
      cd "${BUILD_DIR}/BUILD_GPKG"
      archive_file="${BUILD_DIR}/BUILD_TMP/${GPKG_NAME}.archive"
      curl -w "(DL) <== %{url}\n" -qfsSL "${GPKG_SRCURL}" -o "${archive_file}"
      file_type="$(file -b "${archive_file}" 2>/dev/null)"
      case "$file_type" in
        *"gzip compressed"*|*"tar archive"*)
            if tar -tzf "${archive_file}" &>/dev/null; then
                tar -xzf "${archive_file}" --strip-components=1 2>/dev/null || {
                    echo -e "[-] Failed to strip components, extracting normally"
                    tar -xzf "${archive_file}" 2>/dev/null
                    top_dirs=(*)
                    if [[ ${#top_dirs[@]} -eq 1 && -d "${top_dirs[0]}" ]]; then
                        log_verbose "Moving contents from ${top_dirs[0]}/ to current directory"
                        mv "${top_dirs[0]}"/* . 2>/dev/null || true
                        mv "${top_dirs[0]}"/.[!.]* . 2>/dev/null || true
                        rmdir "${top_dirs[0]}" 2>/dev/null || true
                    fi
                }
            fi
            ;;
        *"Zip archive"*)
            if unzip -o -q "${archive_file}" -d "${BUILD_DIR}/BUILD_GPKG" 2>/dev/null; then
                top_dirs=(*)
                if [[ ${#top_dirs[@]} -eq 1 && -d "${top_dirs[0]}" && "${top_dirs[0]}" != "repo.archive" ]]; then
                    log_verbose "Moving contents from ${top_dirs[0]}/ to current directory"
                    mv "${top_dirs[0]}"/* . 2>/dev/null || true
                    mv "${top_dirs[0]}"/.[!.]* . 2>/dev/null || true
                    rmdir "${top_dirs[0]}" 2>/dev/null || true
                fi
            fi
            ;;
      esac
      unset archive_file file_type top_dirs
   else
     #Clone
      cd "${BUILD_DIR}" &&\
      rm -rf "./BUILD_GPKG" 2>/dev/null
      git clone --depth="1" --filter="blob:none" "${GPKG_SRCURL}" "./BUILD_GPKG"
      pushd "${BUILD_DIR}/BUILD_GPKG" &>/dev/null
   fi
  #Check
   if [[ "$(du -s "${BUILD_DIR}/BUILD_GPKG" | cut -f1)" -lt 10 ]]; then
      echo -e "\n[✗] FATAL: Pkg Download/Extraction probably Failed\n"
      du -bh "${BUILD_DIR}/BUILD_TMP/${GPKG_NAME}.archive" 2>/dev/null
      du -bh "${BUILD_DIR}/BUILD_GPKG"
      ls -lah "${BUILD_DIR}/BUILD_GPKG"
      build_fail_gh
     exit 1
   else
     #Pkg [Is Lib?]
      if _detect_if_cli "${GPKG_SRCURL}" --quiet --simple 2>/dev/null | grep -m 1 -qoiE 'library'; then
         echo -e "\n[-] WARNING: ${GPKG_NAME} is likely a Library\n"
         export GPKG_TYPE="library"
         [[ "${GHA_MODE}" == "MATRIX" ]] && echo "GPKG_TYPE=library" >> "${GITHUB_ENV}"
      fi
     #Meta (Raw)
      if [[ -s "${GPKG_META_RAW}" ]]; then
        cp -fv "${GPKG_META_RAW}" "${BUILD_DIR}/GPKG_META_RAW.json"
      fi
     #Meta (Cleaned)
      if [[ -s "${GPKG_META}" ]]; then
        cp -fv "${GPKG_META}" "${BUILD_DIR}/GPKG_META.json"
      fi
   fi
  #Build
   echo -e "\n[+] Artifacts: ${G_ARTIFACT_DIR}\n"
   {
     pushd "${BUILD_DIR}/BUILD_GPKG" &>/dev/null
     echo '\\\\========================== Package Forge ===========================////'
     echo '|--- Repository: https://github.com/pkgforge-go/builder                 ---|'
     echo '|--- Contact: https://docs.pkgforge.dev/contact/chat                    ---|'
     echo '|--- Discord: https://discord.gg/djJUs48Zbu                             ---|'  
     echo '|--- Docs: https://docs.pkgforge.dev/repositories/external/pkgforge-go  ---|'
     echo '|--- Bugs/Issues: https://github.com/pkgforge-go/builder/issues         ---|'
     echo '|--------------------------------------------------------------------------|'
     echo -e "\n==> [+] Started Building at :: $(TZ='UTC' date +'%A, %Y-%m-%d (%I:%M:%S %p)') UTC\n"
     presetup_go
     set_goflags && go_build
     echo -e "\n==> [+] Finished Building at :: $(TZ='UTC' date +'%A, %Y-%m-%d (%I:%M:%S %p)') UTC\n"
   } |& ts -s '[%H:%M:%S]➜ ' | tee "${G_ARTIFACT_DIR}/BUILD.log"
  #Check Dir
   if [[ "$(du -s --exclude='*.log' "${G_ARTIFACT_DIR}" | cut -f1)" -lt 10 ]]; then
      echo -e "\n[✗] FATAL: ${G_ARTIFACT_DIR} seems broken\n"
      du -bh "${G_ARTIFACT_DIR}"
      ls -lah "${G_ARTIFACT_DIR}"
      build_fail_gh
     exit 1
   else
      PROGS=()
      mapfile -t PROGS < <(find "${G_ARTIFACT_DIR}" -maxdepth 1 -type f -exec file -i "{}" \; | \
                     grep -Ei "application/.*executable" | \
                     cut -d":" -f1 | \
                     xargs realpath --no-symlinks | \
                     xargs -I "{}" basename "{}")
      if [[ ${#PROGS[@]} -le 0 ]]; then
         echo -e "\n[✗] FATAL: Failed to find any Executables\n"
         build_fail_gh
        exit 1
      fi
   fi
  #Gen Metadata
   cd "${G_ARTIFACT_DIR}"
   for PROG in "${PROGS[@]}"; do
    #clean
     unset BUILD_GHACTIONS BUILD_ID BUILD_LOG DOWNLOAD_URL GHCRPKG_RAND GHCRPKG_TAG GHCRPKG_URL ghcr_push_cmd PKG_BSUM PKG_CATEGORY PKG_DATE PKG_DATETMP PKG_DESCRIPTION PKG_DOWNLOAD_COUNT PKG_FAMILY PKG_HOMEPAGE PKG_JSON PKG_ID PKG_ID_TMP PKG_LICENSE PKG_NAME PKG_PROVIDES PKG_SHASUM PKG_SIZE PKG_SIZE_RAW PKG_SRC_URL PKG_TAGS PKG_TYPE PKG_VERSION PKG_WEBPAGE SNAPSHOT_JSON SNAPSHOT_TAGS TAG_URL
    #Check
     if [[ ! -s "./${PROG}" ]]; then
        echo -e "\n[-] Skipping ${PROG} - file does not exist or is empty\n"
        continue
     else
        echo -e "\n[+] Processing ${PROG} [${GPKG_NAME}]\n"
     fi
    #Name
     PKG_NAME="$(basename "${PROG}" | tr -d '[:space:]')"
     PKG_FAMILY="${GPKG_NAME##*[[:space:]]}"
     echo "[+] Name: ${PKG_NAME}"
     echo "[+] Pkg: ${PKG_FAMILY}"
     export PKG_NAME PKG_FAMILY
     [[ "${GHA_MODE}" == "MATRIX" ]] && echo "PKG_NAME=${PKG_NAME}" >> "${GITHUB_ENV}"
    #Version
     PKG_VERSION="${GPKG_VERSION##*[[:space:]]}"
     PKG_VERSION_UPSTREAM="${GPKG_VERSION_UPSTREAM##*[[:space:]]}"
     echo "[+] Version: ${PKG_VERSION} (Upstream: ${PKG_VERSION_UPSTREAM})"
     export PKG_VERSION PKG_VERSION_UPSTREAM
     [[ "${GHA_MODE}" == "MATRIX" ]] && echo "PKG_VERSION=${PKG_VERSION}" >> "${GITHUB_ENV}"
    #Checksums
     PKG_BSUM="$(b3sum "${PROG}" | grep -oE '^[a-f0-9]{64}' | tr -d '[:space:]')"
     PKG_SHASUM="$(sha256sum "${PROG}" | grep -oE '^[a-f0-9]{64}' | tr -d '[:space:]')"
     echo "[+] blake3sum: ${PKG_BSUM}"
     echo "[+] sha256sum: ${PKG_SHASUM}"
     export PKG_BSUM PKG_SHASUM
    #Date
     PKG_DATETMP="$(date --utc +%Y-%m-%dT%H:%M:%S)Z"
     PKG_DATE="$(echo "${PKG_DATETMP}" | sed 's/ZZ\+/Z/Ig')"
     echo "[+] Build Date: ${PKG_DATE}"
     export PKG_DATETMP PKG_DATE
     [[ "${GHA_MODE}" == "MATRIX" ]] && echo "PKG_DATE=${PKG_DATE}" >> "${GITHUB_ENV}"
    #Description 
     PKG_DESCRIPTION="${GPKG_DESCR}"
      if [[ "$(echo "${PKG_DESCRIPTION}" | tr -d '[:space:]' | wc -c)" -ge 5 ]]; then
        echo "[+] Description: ${PKG_DESCRIPTION}"
      else
        PKG_DESCRIPTION="No Description Provided"
      fi
     export PKG_DESCRIPTION
    #Download Count
     [[ -s "${GPKG_META}" ]] && PKG_DOWNLOAD_COUNT="$(jq -r '.. | objects | select(has("stars")) | .stars' "${GPKG_META}" | grep -iv 'null' | head -n 1 | tr -cd '[:digit:]')"
      if [[ "$(echo "${PKG_DOWNLOAD_COUNT}" | tr -d '[:space:]')" -ge 5 ]]; then
        echo "[+] Download Count: ${PKG_DOWNLOAD_COUNT}"
      else
        PKG_DOWNLOAD_COUNT="-1"
      fi
     export PKG_DOWNLOAD_COUNT
    #GHCR
     GHCRPKG_TAG="${PKG_VERSION}-${HOST_TRIPLET}"
     GHCRPKG_RAND="$(echo "${GPKG_ID}" | awk -F'_' '{for(i=1;i<=NF;i++) if($i!="") a[++n]=$i; if(n>=3) print a[n-1]"/"a[n]; else if(n==2) print a[2]; delete a; n=0}' | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
     if echo "${GPKG_SRCURL}" | grep -qi "bitbucket.org"; then
        GPKG_FORGE="bitbucket"
     elif echo "${GPKG_SRCURL}" | grep -qi "buildroot.net"; then
        GPKG_FORGE="buildroot"
     elif echo "${GPKG_SRCURL}" | grep -qi "codeberg.org"; then
        GPKG_FORGE="codeberg"
     elif echo "${GPKG_SRCURL}" | grep -qi "gitee"; then
        GPKG_FORGE="gitee"
     elif echo "${GPKG_SRCURL}" | grep -qi "github.com"; then
        GPKG_FORGE="github"
     elif echo "${GPKG_SRCURL}" | grep -qi "gitlab.com"; then
        GPKG_FORGE="gitlab"
     elif echo "${GPKG_SRCURL}" | grep -qi "gnu.org"; then
        GPKG_FORGE="gnu"
     elif echo "${GPKG_SRCURL}" | grep -qi "sr.ht"; then
        GPKG_FORGE="sourcehut"
     elif echo "${GPKG_SRCURL}" | grep -qi "sourceforge.net"; then
        GPKG_FORGE="sourceforge"
     else
        GPKG_FORGE="misc"
     fi
     GHCRPKG_URL="$(echo "ghcr.io/pkgforge-go/${GPKG_FORGE}/${GHCRPKG_RAND:-stable}/${PROG}" | sed ':a; s|^\(https://\)\([^/]\)/\(/\)|\1\2/\3|; ta' | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
     echo "[+] GHCR (TAG): ${GHCRPKG_TAG}"
     echo "[+] GHCR (URL): ${GHCRPKG_URL}"
     export GHCRPKG_TAG GHCRPKG_URL GPKG_FORGE
     [[ "${GHA_MODE}" == "MATRIX" ]] && echo "GHCRPKG_URL=${GHCRPKG_URL}" >> "${GITHUB_ENV}"
     [[ "${GHA_MODE}" == "MATRIX" ]] && echo "GHCRPKG_TAG=${GHCRPKG_TAG}" >> "${GITHUB_ENV}"
     [[ "${GHA_MODE}" == "MATRIX" ]] && echo "GPKG_FORGE=${GPKG_FORGE}" >> "${GITHUB_ENV}"
    #Download URL
     DOWNLOAD_URL="$(echo "${GHCRPKG_URL}" | sed 's|^ghcr.io|https://api.ghcr.pkgforge.dev|' | sed ':a; s|^\(https://\)\([^/]\)/\(/\)|\1\2/\3|; ta')?tag=${GHCRPKG_TAG}&download=${PROG}"
     BUILD_LOG="$(echo "${DOWNLOAD_URL}" | sed 's/download=[^&]*/download='"${PROG}"'.log/')"
     echo "[+] Build Log: ${DOWNLOAD_URL}"
     echo "[+] Download URL: ${DOWNLOAD_URL}"
     export BUILD_LOG DOWNLOAD_URL
     [[ "${GHA_MODE}" == "MATRIX" ]] && echo "DOWNLOAD_URL=${DOWNLOAD_URL}" >> "${GITHUB_ENV}"
    #HomePage  
     PKG_HOMEPAGE="${GPKG_HOMEPAGE}"
      if [[ "$(echo "${PKG_HOMEPAGE}" | tr -d '[:space:]' | wc -c)" -ge 5 ]]; then
        echo "[+] Homepage: ${PKG_HOMEPAGE}"
      else
        PKG_HOMEPAGE=""
      fi
     export PKG_HOMEPAGE
    #ID
     BUILD_ID="${GITHUB_RUN_ID}"
     BUILD_GHACTIONS="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
     PKG_ID_TMP="${PKG_NAME}#${GPKG_ID:-pkgforge-go.${GPKG_NAME}.stable}"
     PKG_ID="$(echo "${PKG_ID_TMP}" | awk '{i=index($0,"#"); h=substr($0,1,i); t=substr($0,i+1); gsub(/^https?:\/\//,"",t); gsub(/[^a-zA-Z0-9.]/,"_",t); gsub(/_+/,"_",t); sub(/^_+/,"",t); sub(/_+$/,"",t); print h t}' | tr -d '"'\''[:space:]')"
     export BUILD_ID BUILD_GHACTIONS PKG_ID
     [[ "${GHA_MODE}" == "MATRIX" ]] && echo "BUILD_GHACTIONS=${BUILD_GHACTIONS}" >> "${GITHUB_ENV}"
     [[ "${GHA_MODE}" == "MATRIX" ]] && echo "BUILD_ID=${BUILD_ID}" >> "${GITHUB_ENV}"
    #License
     [[ -s "${GPKG_META}" ]] && PKG_LICENSE="$(jq -r '.. | objects | select(has("license")) | .license | if type == "array" then join(", ") else . end' "${GPKG_META}" | grep -iv 'null' | head -n 1 | sed 's/"//g' | sed 's/^[ \t]*//;s/[ \t]*$//' | sed 's/["'\'']//g' | sed 's/|//g' | sed 's/`//g' | sed 's/^, //; s/, $//')"
     if [[ "$(echo "${PKG_LICENSE}" | tr -d '[:space:]' | wc -c)" -ge 2 ]]; then
       echo "[+] License: ${PKG_LICENSE}"
     else
       PKG_LICENSE="Blessing"
     fi
     export PKG_LICENSE
    #Provides
     PKG_PROVIDES="$(printf '%s\n' "${PROGS[@]}" | paste -sd, - | tr -d '[:space:]' | sed 's/, /, /g' | sed 's/,/, /g' | sed 's/|//g' | sed 's/"//g' | sed 's/^, //; s/, $//')"
     if [[ "$(echo "${PKG_PROVIDES}" | tr -d '[:space:]' | wc -c)" -ge 2 ]]; then
       echo "[+] Provides: ${PKG_PROVIDES}"
     else
       PKG_PROVIDES="${PKG_NAME}"
     fi
     export PKG_PROVIDES
    #Size
     PKG_SIZE="$(du -bh "${PROG}" | awk '{unit=substr($1,length($1)); sub(/[BKMGT]$/,"",$1); print $1 " " unit "B"}')"
     PKG_SIZE_RAW="$(stat --format="%s" "${PROG}" | tr -d '[:space:]')"
     echo "[+] Size: ${PKG_SIZE}"
     echo "[+] Size (RAW): ${PKG_SIZE_RAW}"
     export PKG_SIZE PKG_SIZE_RAW
    #Src
     PKG_WEBPAGE="${GPKG_HOMEPAGE}"
     PKG_SRC_URL="${GPKG_SRCURL}"
     echo "[+] Src URL: ${PKG_SRC_URL}"
     export PKG_SRC_URL PKG_WEBPAGE
     [[ "${GHA_MODE}" == "MATRIX" ]] && echo "PKG_SRC_URL=${PKG_SRC_URL}" >> "${GITHUB_ENV}"
     [[ "${GHA_MODE}" == "MATRIX" ]] && echo "PKG_WEBPAGE=${PKG_WEBPAGE}" >> "${GITHUB_ENV}"
    #Tags
     [[ -s "${GPKG_META}" ]] && PKG_TAGS="$(jq -r '.. | objects | select(has("tag")) | .tag | if type == "array" then join(", ") else . end' "${GPKG_META}" | tr -d '[]' | sort -u | grep -iv 'null' | paste -sd, - | tr -d '[:space:]' | sed 's/, /, /g' | sed 's/,/, /g' | sed 's/|//g' | sed 's/"//g' | sed 's/^, //; s/, $//')"
     if [[ "$(echo "${PKG_TAGS}" | tr -d '[:space:]' | wc -c)" -ge 3 ]]; then
       echo "[+] Tags: ${PKG_TAGS}"
     else
       PKG_TAGS="Utility"
     fi
     PKG_CATEGORY="Utility"
     export PKG_CATEGORY PKG_TAGS
    #Type
     PKG_TYPE="static"
     export PKG_TYPE
     [[ "${GHA_MODE}" == "MATRIX" ]] && echo "PKG_TYPE=${PKG_TYPE}" >> "${GITHUB_ENV}"
    #Generate Snapshots
     if [[ -n "${GHCRPKG_URL+x}" ]] && [[ "${GHCRPKG_URL}" =~ ^[^[:space:]]+$ ]]; then
      #Generate Manifest
       unset PKG_GHCR PKG_MANIFEST METADATA_URL
       PKG_MANIFEST="$(echo "${DOWNLOAD_URL}" | sed 's/download=[^&]*/manifest/')"
       METADATA_URL="$(echo "${DOWNLOAD_URL}" | sed 's/download=[^&]*/download='"${PROG}"'.json/')"
       PKG_GHCR="${GHCRPKG_URL}:${GHCRPKG_TAG}"
       export PKG_GHCR PKG_MANIFEST
      #Generate Tags
       TAG_URL="https://api.ghcr.pkgforge.dev/$(echo "${GHCRPKG}" | sed ':a; s|^\(https://\)\([^/]\)/\(/\)|\1\2/\3|; ta' | sed -E 's|^ghcr\.io/||; s|^/+||; s|/+?$||' | sed ':a; s|^\(https://\)\([^/]\)/\(/\)|\1\2/\3|; ta')/${PROG}?tags"
       echo -e "[+] Fetching Snapshot Tags <== ${TAG_URL} [\$GHCRPKG]"
       readarray -t "SNAPSHOT_TAGS" < <(oras repo tags "${GHCRPKG_URL}" | grep -viE '^\s*(latest|srcbuild)[.-][0-9]{6}T[0-9]{6}[.-]' | grep -i "${HOST_TRIPLET%%-*}" | uniq)
     else
       TAG_URL="https://api.ghcr.pkgforge.dev/pkgforge/$(echo "${PKG_REPO}/${PKG_FAMILY:-${PKG_NAME}}/${PKG_NAME:-${PKG_FAMILY:-${PKG_ID}}}" | sed ':a; s|^\(https://\)\([^/]\)/\(/\)|\1\2/\3|; ta')/${PROG}?tags"
       echo -e "[+] Fetching Snapshot Tags <== ${TAG_URL} [NO \$GHCRPKG]"
       readarray -t "SNAPSHOT_TAGS" < <(oras repo tags "${GHCRPKG_URL}" | grep -viE '^\s*(latest|srcbuild)[.-][0-9]{6}T[0-9]{6}[.-]' | grep -i "${HOST_TRIPLET%%-*}" | uniq)
     fi
     if [[ -n "${SNAPSHOT_TAGS[*]}" && "${#SNAPSHOT_TAGS[@]}" -gt 0 ]]; then
       echo -e "[+] Snapshots: ${SNAPSHOT_TAGS[*]}"
       unset S_TAG S_TAGS S_TAG_VALUE SNAPSHOT_JSON ; S_TAGS=()
       for S_TAG in "${SNAPSHOT_TAGS[@]}"; do
        S_TAG_VALUE="$(oras manifest fetch "${GHCRPKG_URL}:${S_TAG}" | jq -r '.annotations["dev.pkgforge.soar.version_upstream"]' | tr -d '[:space:]')"
        [[ "${S_TAG_VALUE}" == "null" ]] && unset S_TAG_VALUE
         if [[ -n "${S_TAG_VALUE+x}" ]] && [[ "${S_TAG_VALUE}" =~ ^[^[:space:]]+$ ]]; then
           S_TAGS+=("${S_TAG}[${S_TAG_VALUE}]")
         else
           S_TAGS+=("${S_TAG}")
         fi
       done
       if [[ -n "${S_TAGS[*]}" && "${#S_TAGS[@]}" -gt 0 ]]; then
         SNAPSHOT_JSON=$(printf '%s\n' "${S_TAGS[@]}" | jq -R . | jq -s 'if type == "array" then . else [] end')
         export SNAPSHOT_JSON
       else
         export SNAPSHOT_JSON="[]"
       fi
       unset S_TAG S_TAGS S_TAG_VALUE
     else
       echo -e "[-] INFO: Snapshots is empty (No Previous Build Exists?)"
       export SNAPSHOT_JSON="[]"
     fi
    #Generate Json
     jq -rn --argjson "snapshots" "${SNAPSHOT_JSON:-[]}" \
      '{
       "_disabled": "false",
       "host": (env.HOST_TRIPLET // ""),
       "rank": (env.RANK // ""),
       "pkg": (env.PKG_NAME // .pkg // ""),
       "pkg_family": (env.PKG_FAMILY // ""),
       "pkg_id": (env.PKG_ID // ""),
       "pkg_name": (env.PKG_NAME // .pkg // ""),
       "pkg_type": (env.PKG_TYPE // .pkg_type // ""),
       "pkg_webpage": (env.PKG_WEBPAGE // ""),
       "bundle": "false",
       "category": (if env.PKG_CATEGORY then (env.PKG_CATEGORY | split(",") | map(gsub("^\\s+|\\s+$"; "")) | unique | sort) else [] end),
       "description": (env.PKG_DESCRIPTION // (if type == "object" and has("description") and (.description | type == "object") then (if env.PROG != null and (.description[env.PROG] != null) then .description[env.PROG] else .description["_default"] end) else .description end // "")),
       "homepage": (if env.PKG_HOMEPAGE then (env.PKG_HOMEPAGE | split(",") | map(gsub("^\\s+|\\s+$"; "")) | unique | sort) else [] end),
       "license": (if env.PKG_LICENSE then (env.PKG_LICENSE | split(",") | map(gsub("^\\s+|\\s+$"; "")) | unique | sort) else [] end),
       "maintainer": ["pkgforge-go (https://github.com/pkgforge-go/builder)"],
       "provides": (if env.PKG_PROVIDES then (env.PKG_PROVIDES | split(",") | map(gsub("^\\s+|\\s+$"; "")) | unique | sort) else [] end),
       "note": [
         "[EXTERNAL] (This is an Official but externally maintained repository)",
         "This package was automatically built from source using go+zig",
         "Provided by: https://github.com/pkgforge-go/builder",
         "Learn More: https://docs.pkgforge.dev/repositories/external/pkgforge-go"
       ],
       "src_url": (if env.PKG_SRC_URL then (env.PKG_SRC_URL | split(",") | map(gsub("^\\s+|\\s+$"; "")) | unique | sort) else [] end),
       "tag": (if env.PKG_TAGS then (env.PKG_TAGS | split(",") | map(gsub("^\\s+|\\s+$"; "")) | unique | sort) else [] end),
       "version": (env.PKG_VERSION // ""),
       "version_upstream": (env.PKG_VERSION_UPSTREAM // ""),
       "bsum": (env.PKG_BSUM // ""),
       "build_date": (env.PKG_DATE // ""),
       "build_gha": (env.BUILD_GHACTIONS // ""),
       "build_id": (env.BUILD_ID // ""),
       "build_log": (env.BUILD_LOG // ""),
       "deprecated": (env.PKG_DEPRECATED // "false"),
       "desktop_integration": "false",
       "download_count": ((env.PKG_DOWNLOAD_COUNT // "") | tostring),
       "download_url": (env.DOWNLOAD_URL // ""),
       "external": "true", 
       "ghcr_pkg": (env.PKG_GHCR // ""),
       "ghcr_url": (if (env.GHCRPKG_URL // "") | startswith("https://") then (env.GHCRPKG_URL // "") else "https://" + (env.GHCRPKG_URL // "") end),
       "installable": "true",
       "manifest_url": (env.PKG_MANIFEST // ""),
       "portable": "true",
       "recurse_provides": "false",
       "shasum": (env.PKG_SHASUM // ""),
       "size": (env.PKG_SIZE // ""),
       "size_raw": (env.PKG_SIZE_RAW // ""),
       "soar_syms": "false",
       "snapshots": $snapshots,
       "trusted": "true"
     }' | jq . > "${BUILD_DIR}/BUILD_TMP/${PROG}.json"
     #Copy
       if jq -r '.pkg' "${BUILD_DIR}/BUILD_TMP/${PROG}.json" | grep -iv 'null' | tr -d '[:space:]' | grep -Eiq "^${PKG_NAME}$"; then
         mv -fv "${BUILD_DIR}/BUILD_TMP/${PROG}.json" "${G_ARTIFACT_DIR}/${PROG}.json"
         cp -fv "${G_ARTIFACT_DIR}/BUILD.log" "${G_ARTIFACT_DIR}/${PROG}.log"
         echo "${PKG_VERSION}" | tr -d '[:space:]' > "${G_ARTIFACT_DIR}/${PROG}.version"
         PKG_JSON="${G_ARTIFACT_DIR}/${PROG}.json"
         METADATA_FILE="${METADATA_DIR}/$(echo "${GHCRPKG_URL}" | sed 's/[^a-zA-Z0-9]/_/g' | tr -d '"'\''[:space:]')-${HOST_TRIPLET}.json"
         cp -fv "${PKG_JSON}" "${METADATA_FILE}"
         export PKG_JSON
         echo -e "\n[+] Metadata: \n" && jq . "${PKG_JSON}" ; echo -e "\n"
       else
          echo -e "\n[✗] FATAL: Failed to generate Metadata\n"
          build_fail_gh
         exit 1
       fi
    #Upload to ghcr
     #Construct Upload CMD
      ghcr_push_cmd()
      {
       for i in {1..10}; do
         unset ghcr_push ; ghcr_push=(oras push --disable-path-validation)
         ghcr_push+=(--config "/dev/null:application/vnd.oci.empty.v1+json")
         ghcr_push+=(--annotation "com.github.package.type=container")
         ghcr_push+=(--annotation "dev.pkgforge.discord=https://discord.gg/djJUs48Zbu")
         ghcr_push+=(--annotation "dev.pkgforge.soar.build_date=${PKG_DATE}")
         ghcr_push+=(--annotation "dev.pkgforge.soar.build_gha=${BUILD_GHACTIONS}")
         ghcr_push+=(--annotation "dev.pkgforge.soar.build_id=${BUILD_ID}")
         ghcr_push+=(--annotation "dev.pkgforge.soar.build_log=${BUILD_LOG}")
         ghcr_push+=(--annotation "dev.pkgforge.soar.bsum=${PKG_BSUM}")
         ghcr_push+=(--annotation "dev.pkgforge.soar.category=${PKG_CATEGORY}")
         ghcr_push+=(--annotation "dev.pkgforge.soar.description=${PKG_DESCRIPTION}")
         ghcr_push+=(--annotation "dev.pkgforge.soar.download_url=${DOWNLOAD_URL}")
         ghcr_push+=(--annotation "dev.pkgforge.soar.ghcr_pkg=${GHCRPKG_URL}:${GHCRPKG_TAG}")
         ghcr_push+=(--annotation "dev.pkgforge.soar.homepage=${PKG_HOMEPAGE:-${PKG_SRC_URL}}")
         ghcr_push+=(--annotation "dev.pkgforge.soar.json=$(jq . ${PKG_JSON})")
         ghcr_push+=(--annotation "dev.pkgforge.soar.manifest_url=${PKG_MANIFEST}")
         ghcr_push+=(--annotation "dev.pkgforge.soar.metadata_url=${METADATA_URL}")
         ghcr_push+=(--annotation "dev.pkgforge.soar.pkg=${PKG_NAME}")
         ghcr_push+=(--annotation "dev.pkgforge.soar.pkg_family=${PKG_FAMILY}")
         ghcr_push+=(--annotation "dev.pkgforge.soar.pkg_name=${PKG_NAME}")
         ghcr_push+=(--annotation "dev.pkgforge.soar.pkg_webpage=${PKG_WEBPAGE}")
         ghcr_push+=(--annotation "dev.pkgforge.soar.shasum=${PKG_SHASUM}")
         ghcr_push+=(--annotation "dev.pkgforge.soar.size=${PKG_SIZE}")
         ghcr_push+=(--annotation "dev.pkgforge.soar.size_raw=${PKG_SIZE_RAW}")
         ghcr_push+=(--annotation "dev.pkgforge.soar.src_url=${PKG_SRC_URL:-${PKG_HOMEPAGE}}")
         ghcr_push+=(--annotation "dev.pkgforge.soar.version=${PKG_VERSION}")
         ghcr_push+=(--annotation "dev.pkgforge.soar.version_upstream=${PKG_VERSION_UPSTREAM}")
         ghcr_push+=(--annotation "org.opencontainers.image.authors=https://docs.pkgforge.dev/contact/chat")
         ghcr_push+=(--annotation "org.opencontainers.image.created=${PKG_DATE}")
         ghcr_push+=(--annotation "org.opencontainers.image.description=${PKG_DESCRIPTION}")
         ghcr_push+=(--annotation "org.opencontainers.image.documentation=${PKG_WEBPAGE}")
         ghcr_push+=(--annotation "org.opencontainers.image.licenses=blessing")
         ghcr_push+=(--annotation "org.opencontainers.image.ref.name=${PKG_VERSION}")
         ghcr_push+=(--annotation "org.opencontainers.image.revision=${PKG_SHASUM:-${PKG_VERSION}}")
         ghcr_push+=(--annotation "org.opencontainers.image.source=https://github.com/pkgforge-go/${PKG_REPO}")
         ghcr_push+=(--annotation "org.opencontainers.image.title=${PKG_NAME}")
         ghcr_push+=(--annotation "org.opencontainers.image.url=${PKG_SRC_URL}")
         ghcr_push+=(--annotation "org.opencontainers.image.vendor=pkgforge-go")
         ghcr_push+=(--annotation "org.opencontainers.image.version=${PKG_VERSION}")
         ghcr_push+=("${GHCRPKG_URL}:${GHCRPKG_TAG}" "./${PROG}")
         [[ -f "./${PROG}.sig" && -s "./${PROG}.sig" ]] && ghcr_push+=("./${PROG}.sig")
         [[ -f "./CHECKSUM" && -s "./CHECKSUM" ]] && ghcr_push+=("./CHECKSUM")
         [[ -f "./CHECKSUM.sig" && -s "./CHECKSUM.sig" ]] && ghcr_push+=("./CHECKSUM.sig")
         [[ -f "./LICENSE" && -s "./LICENSE" ]] && ghcr_push+=("./LICENSE")
         [[ -f "./LICENSE.sig" && -s "./LICENSE.sig" ]] && ghcr_push+=("./LICENSE.sig")
         [[ -f "./${PROG}.json" && -s "./${PROG}.json" ]] && ghcr_push+=("./${PROG}.json")
         [[ -f "./${PROG}.json.sig" && -s "./${PROG}.json.sig" ]] && ghcr_push+=("./${PROG}.json.sig")
         [[ -f "./${PROG}.log" && -s "./${PROG}.log" ]] && ghcr_push+=("./${PROG}.log")
         [[ -f "./${PROG}.log.sig" && -s "./${PROG}.log.sig" ]] && ghcr_push+=("./${PROG}.log.sig")
         [[ -f "./${PROG}.version" && -s "./${PROG}.version" ]] && ghcr_push+=("./${PROG}.version")
         [[ -f "./${PROG}.version.sig" && -s "./${PROG}.version.sig" ]] && ghcr_push+=("./${PROG}.version.sig")
         "${ghcr_push[@]}" ; sleep 5
        #Check 
         if [[ "$(oras manifest fetch "${GHCRPKG_URL}:${GHCRPKG_TAG}" | jq -r '.annotations["dev.pkgforge.soar.build_date"]' | tr -d '[:space:]')" == "${PKG_DATE}" ]]; then
           echo -e "\n[+] Registry --> https://${GHCRPKG_URL}"
           echo -e "[+] ==> ${MANIFEST_URL:-${DOWNLOAD_URL}} \n"
           export PUSH_SUCCESSFUL="YES"
           #rm -rf "${GHCR_PKG}" "${PKG_JSON}" 2>/dev/null
           [[ "${GHA_MODE}" == "MATRIX" ]] && echo "PKG_VERSION_UPSTREAM=${PKG_VERSION_UPSTREAM}" >> "${GITHUB_ENV}"
           [[ "${GHA_MODE}" == "MATRIX" ]] && echo "GHCRPKG_URL=${GHCRPKG_URL}" >> "${GITHUB_ENV}"
           [[ "${GHA_MODE}" == "MATRIX" ]] && echo "PUSH_SUCCESSFUL=${PUSH_SUCCESSFUL}" >> "${GITHUB_ENV}"
           break
         else
           echo -e "\n[-] Failed to Push Artifact to ${GHCRPKG_URL}:${GHCRPKG_TAG} (Retrying ${i}/10)\n"
         fi
         sleep "$(shuf -i 500-4500 -n 1)e-3"
       done
      }
      export -f ghcr_push_cmd
      #First Set of tries
       ghcr_push_cmd
      #Check if Failed  
       if [[ "$(oras manifest fetch "${GHCRPKG_URL}:${GHCRPKG_TAG}" | jq -r '.annotations["dev.pkgforge.soar.build_date"]' | tr -d '[:space:]')" != "${PKG_DATE}" ]]; then
         echo -e "\n[✗] Failed to Push Artifact to ${GHCRPKG_URL}:${GHCRPKG_TAG}\n"
         #Second set of Tries
          echo -e "\n[-] Retrying ...\n"
          ghcr_push_cmd
           if [[ "$(oras manifest fetch "${GHCRPKG_URL}:${GHCRPKG_TAG}" | jq -r '.annotations["dev.pkgforge.soar.build_date"]' | tr -d '[:space:]')" != "${PKG_DATE}" ]]; then
             oras manifest fetch "${GHCRPKG_URL}:${GHCRPKG_TAG}" | jq .
             echo -e "\n[✗] Failed to Push Artifact to ${GHCRPKG_URL}:${GHCRPKG_TAG}\n"
             export PUSH_SUCCESSFUL="NO"
             [[ "${GHA_MODE}" == "MATRIX" ]] && echo "PUSH_SUCCESSFUL=${PUSH_SUCCESSFUL}" >> "${GITHUB_ENV}"
             return 1 || exit 1
           fi
       fi
  done
  popd &>/dev/null
#-------------------------------------------------------#

#-------------------------------------------------------#
##Upload SRCBUILD
 if [[ -n "${GITHUB_TEST_BUILD+x}" || "${GHA_MODE}" == "MATRIX" ]]; then
  pushd "$(mktemp -d)" &>/dev/null &&\
   tar --directory="${BUILD_DIR}" --preserve-permissions --create --file="BUILD_ARTIFACTS.tar" "."
   zstd --force "./BUILD_ARTIFACTS.tar" --verbose -o "/tmp/BUILD_ARTIFACTS.zstd"
   rm -rvf "./BUILD_ARTIFACTS.tar" 2>/dev/null &&\
  popd &>/dev/null
 elif [[ "${KEEP_LOGS}" != "YES" ]]; then
  echo -e "\n[-] Removing ALL Logs & Files\n"
  rm -rvf "${BUILD_DIR}" 2>/dev/null
 fi
##Disable Debug 
 if [[ "${DEBUG}" = "1" ]] || [[ "${DEBUG}" = "ON" ]]; then
    set -x
 fi
#-------------------------------------------------------#