#!/usr/bin/env bash
#VERSION=0.0.4
#-------------------------------------------------------#
#Entirely Vibe coded by Claude but tested/verified
#Determines if a Go project is a CLI tool or library from a git URL or archive URL
#Self: https://raw.githubusercontent.com/pkgforge-go/builder/refs/heads/main/scripts/_detect_if_cli.sh
#-------------------------------------------------------#

#-------------------------------------------------------#
##Env
set -e
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export CYAN='\033[0;36m'
export MAGENTA='\033[0;35m'
export BOLD='\033[1m'
export DIM='\033[2m'
export NC='\033[0m'
if [[ ! -d "${SYSTMP}" ]]; then
 SYSTMP="$(dirname $(mktemp -u))"
fi
export SYSTMP
##Global Flags
export QUIET=false
export OUTPUT_FORMAT="human"
export VERBOSE=false
##Exit Codes
export EXIT_CLI=0
export EXIT_LIBRARY=1
export EXIT_UNCLEAR=2
export EXIT_ERROR=3
##Log Opts
log_info() { [[ "$QUIET" == true ]] || echo -e "${BLUE}[INFO]${NC} $1" >&2; } ; export -f log_info
log_success() { [[ "$QUIET" == true ]] || echo -e "${GREEN}[SUCCESS]${NC} $1" >&2; } ; export -f log_success
log_warning() { [[ "$QUIET" == true ]] || echo -e "${YELLOW}[WARNING]${NC} $1" >&2; } ; export -f log_warning
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; } ; export -f log_error
log_verbose() { [[ "$VERBOSE" == true ]] && echo -e "${BLUE}[VERBOSE]${NC} $1" >&2; } ; export -f log_verbose
##Cleanup Func
cleanup() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        log_verbose "Cleaning up temporary directory: $TEMP_DIR"
        rm -rf "$TEMP_DIR"
    fi
}
export -f cleanup
trap cleanup EXIT
#-------------------------------------------------------#

#-------------------------------------------------------#
##Usage/Help
usage() {
    cat << EOF
Usage: $0 [OPTIONS] <url>
DESCRIPTION:
  Detects whether a Go project is a CLI tool or library by analyzing its structure,
  code patterns, and documentation. Supports both git URLs and direct archive URLs.
OPTIONS:
  -q, --quiet         Suppress progress messages (only output result)
  -j, --json          Output result in JSON format
  -s, --simple        Output simple format: 'cli', 'library', or 'unclear'
  -v, --verbose       Show detailed analysis information
  -h, --help          Show this help message
SUPPORTED URL FORMATS:
  Git URLs:
    https://github.com/user/repo
    https://github.com/user/repo.git
    github.com/user/repo
    
  Archive URLs:
    https://github.com/user/repo/archive/refs/heads/main.tar.gz
    https://github.com/user/repo/archive/refs/tags/v1.0.0.tar.gz
    https://api.github.com/repos/user/repo/tarball/main
    Any direct .tar.gz/.tgz/.zip archive URL
OUTPUT FORMATS:
  human (default)     Human-readable output with colors and details
  json               JSON format for programmatic consumption
  simple             Single word: cli, library, or unclear
EXIT CODES:
  0                  CLI tool detected
  1                  Library detected  
  2                  Unclear/ambiguous result
  3                  Error occurred
EXAMPLES:
  $0 https://github.com/spf13/cobra
  $0 -q -s github.com/golang/go
  $0 --json https://github.com/gin-gonic/gin/archive/refs/heads/master.tar.gz
  
PIPELINE USAGE:
  # Check if it's a CLI and install it
  if $0 -q github.com/user/project; then
    go install github.com/user/project@latest
  fi
  
  # Get result as JSON for further processing
  result=\$($0 --json github.com/user/project)
  
  # Simple conditional based on type
  case \$($0 -s github.com/user/project) in
    "cli") echo "Installing CLI tool..." ;;
    "library") echo "Adding to go.mod..." ;;
    *) echo "Manual inspection needed" ;;
  esac
EOF
    exit 1
}
#-------------------------------------------------------#
#-------------------------------------------------------#
##Detect URL type and normalize
detect_url_type() {
    local raw_url="$1"
    local url
    
    #Trim leading/trailing whitespace
    url="$(echo "$raw_url" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
    #Remove URL query parameters and fragments
    url="${url%%[\?#]*}"
    
    #Check if it's an archive URL
    if [[ "$url" =~ \.(tar\.gz|tgz|zip)$ ]] || [[ "$url" =~ /tarball/ ]] || [[ "$url" =~ /zipball/ ]] || [[ "$url" =~ /archive/ ]]; then
        echo "archive"
        return 0
    fi
    
    #Otherwise, treat as git URL
    echo "git"
    return 0
}
##Normalize Git URLs
normalize_git_url() {
    local raw_url="$1"
    local url
    #Trim leading/trailing whitespace
    url="$(echo "$raw_url" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
    #Remove URL query parameters and fragments
    url="${url%%[\?#]*}"
    #Add https:// if missing
    if [[ ! "$url" =~ ^https?:// ]]; then
        url="https://$url"
    fi

    #Ensure .git suffix for cloning (preserve only if not already present)
    if [[ ! "$url" =~ \.git$ ]]; then
        url="${url}.git"
    fi
    echo "$url"
}
##Normalize Archive URLs
normalize_archive_url() {
    local raw_url="$1"
    local url
    #Trim leading/trailing whitespace
    url="$(echo "$raw_url" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
    #Remove URL query parameters and fragments
    url="${url%%[\?#]*}"
    #Add https:// if missing
    if [[ ! "$url" =~ ^https?:// ]]; then
        url="https://$url"
    fi
    echo "$url"
}
#-------------------------------------------------------#

#-------------------------------------------------------#
##Download and extract archive
download_and_extract_archive() {
    local archive_url="$1"
    local repo_dir="$2"
    local archive_file="$repo_dir/repo.archive"
    
    log_info "Downloading archive from: $archive_url"
    
    #Create repo directory
    mkdir -p "$repo_dir"
    
    #Download archive with retry logic
    for i in {1..3}; do
        if curl -qfsSL "$archive_url" --retry 3 --retry-delay 1 --retry-max-time 30 -o "$archive_file"; then
            log_verbose "Archive downloaded successfully"
            break
        fi
        if [[ $i -eq 3 ]]; then
            log_error "Failed to download archive: $archive_url"
            return 1
        fi
        log_verbose "Download attempt $i failed, retrying..."
        sleep $((2 ** (i - 1)))
    done
    
    #Check if file was downloaded and has content
    if [[ ! -f "$archive_file" || ! -s "$archive_file" ]]; then
        log_error "Downloaded archive is empty or missing: $archive_url"
        return 1
    fi
    
    #Extract archive
    log_info "Extracting archive..."
    cd "$repo_dir"
    
    #Detect archive type and extract accordingly
    local file_type
    file_type=$(file -b "$archive_file" 2>/dev/null || echo "unknown")
    
    case "$file_type" in
        *"gzip compressed"*|*"tar archive"*)
            if tar -tzf "$archive_file" >/dev/null 2>&1; then
                log_verbose "Extracting tar.gz archive"
                tar -xzf "$archive_file" --strip-components=1 2>/dev/null || {
                    log_warning "Failed to strip components, extracting normally"
                    tar -xzf "$archive_file" 2>/dev/null || {
                        log_error "Failed to extract tar.gz archive"
                        return 1
                    }
                    #If we couldn't strip components, find the top-level directory and move contents
                    local top_dirs=(*)
                    if [[ ${#top_dirs[@]} -eq 1 && -d "${top_dirs[0]}" ]]; then
                        log_verbose "Moving contents from ${top_dirs[0]}/ to current directory"
                        mv "${top_dirs[0]}"/* . 2>/dev/null || true
                        mv "${top_dirs[0]}"/.[!.]* . 2>/dev/null || true
                        rmdir "${top_dirs[0]}" 2>/dev/null || true
                    fi
                }
            else
                log_error "Invalid tar.gz archive"
                return 1
            fi
            ;;
        *"Zip archive"*)
            if command -v unzip >/dev/null 2>&1; then
                log_verbose "Extracting zip archive"
                unzip -o -q "$archive_file" -d "$repo_dir" 2>/dev/null || {
                    log_error "Failed to extract zip archive"
                    return 1
                }
                #Handle zip extraction similar to tar
                local top_dirs=(*)
                if [[ ${#top_dirs[@]} -eq 1 && -d "${top_dirs[0]}" && "${top_dirs[0]}" != "repo.archive" ]]; then
                    log_verbose "Moving contents from ${top_dirs[0]}/ to current directory"
                    mv "${top_dirs[0]}"/* . 2>/dev/null || true
                    mv "${top_dirs[0]}"/.[!.]* . 2>/dev/null || true
                    rmdir "${top_dirs[0]}" 2>/dev/null || true
                fi
            else
                log_error "unzip command not available for zip archive"
                return 1
            fi
            ;;
        *)
            #Try to extract as tar.gz first, then zip
            log_verbose "Unknown file type, trying tar.gz extraction"
            if tar -tzf "$archive_file" >/dev/null 2>&1 && tar -xzf "$archive_file" --strip-components=1 2>/dev/null; then
                log_verbose "Successfully extracted as tar.gz"
            elif command -v unzip >/dev/null 2>&1 && unzip -tq "$archive_file" >/dev/null 2>&1; then
                log_verbose "Trying zip extraction"
                unzip -q "$archive_file" 2>/dev/null || {
                    log_error "Failed to extract as zip"
                    return 1
                }
                #Handle directory structure
                local top_dirs=(*)
                if [[ ${#top_dirs[@]} -eq 1 && -d "${top_dirs[0]}" && "${top_dirs[0]}" != "repo.archive" ]]; then
                    log_verbose "Moving contents from ${top_dirs[0]}/ to current directory"
                    mv "${top_dirs[0]}"/* . 2>/dev/null || true
                    mv "${top_dirs[0]}"/.[!.]* . 2>/dev/null || true
                    rmdir "${top_dirs[0]}" 2>/dev/null || true
                fi
            else
                log_error "Unable to extract archive (unsupported format or corrupted)"
                return 1
            fi
            ;;
    esac
    
    #Clean up archive file
    rm -f "$archive_file"
    
    #Go back to original directory
    cd - >/dev/null
    
    log_success "Archive extracted successfully"
    return 0
}
#-------------------------------------------------------#
#-------------------------------------------------------#
##Clone Git repository
clone_git_repository() {
    local git_url="$1"
    local repo_dir="$2"
    
    log_info "Cloning Git repository: $git_url"
    
    #Clone with retry logic
    for i in {1..3}; do
        if git clone --depth="1" --filter="blob:none" --quiet "$git_url" "$repo_dir" 2>/dev/null; then
            log_success "Repository cloned successfully"
            return 0
        fi
        if [[ $i -eq 3 ]]; then
            log_error "Failed to clone repository: $git_url"
            return 1
        fi
        log_verbose "Clone attempt $i failed, retrying..."
        sleep $((2 ** (i - 1)))
    done
}
#-------------------------------------------------------#

#-------------------------------------------------------#
##Check if project has main packages (excluding examples/demos)
check_main_packages() {
    local repo_dir="$1"
    local main_count=0
    local go_files=()
    local significant_mains=0
    
    log_verbose "Checking for main packages (excluding examples)..."
    
    #Collect all .go files efficiently
    readarray -t go_files < <(find "$repo_dir" -name "*.go" -type f 2>/dev/null)
    [[ ${#go_files[@]} -eq 0 ]] && {
        # Fallback: use shell globbing
        shopt -s globstar nullglob 2>/dev/null
        go_files=("$repo_dir"/**/*.go "$repo_dir"/*.go)
        shopt -u globstar nullglob 2>/dev/null
    }
    
    #Use grep with multiple files for better performance
    local main_pattern_files=()
    readarray -t main_pattern_files < <(printf '%s\n' "${go_files[@]}" | xargs -r grep -l "^[[:space:]]*package[[:space:]]\+main" 2>/dev/null)
    
    #Count and categorize findings
    for file in "${main_pattern_files[@]}"; do
        [[ -n "$file" ]] || continue
        
        local rel_path="${file#$repo_dir/}"
        log_verbose "Found main package in: $rel_path"
        ((main_count++))
        
        #Check if this is a significant main (not in example/demo directories)
        if [[ ! "$rel_path" =~ ^(example|examples|demo|demos|test|tests|_example|_examples)/ && 
              ! "$rel_path" =~ /example/ && 
              ! "$rel_path" =~ /examples/ && 
              ! "$rel_path" =~ /demo/ && 
              ! "$rel_path" =~ /demos/ && 
              ! "$rel_path" =~ /test/ && 
              ! "$rel_path" =~ /_test\.go$ ]]; then
            log_verbose "  → Significant main package (not in example/demo/test directory)"
            ((significant_mains++))
        else
            log_verbose "  → Example/demo/test main package (ignoring for classification)"
        fi
    done
    
    #Return the count of significant mains, not total mains
    echo "$significant_mains"
}
#-------------------------------------------------------#

#-------------------------------------------------------#
##Check directory structure indicators
check_directory_structure() {
    local repo_dir="$1"
    local score=0
    local dirs=()
    
    log_verbose "Analyzing directory structure..."
    
    #Collect directories efficiently
    readarray -t dirs < <(find "$repo_dir" -maxdepth 1 -type d -name "[!.]*" 2>/dev/null)
    
    #Check for CLI-indicating patterns
    if [[ -d "$repo_dir/cmd" ]]; then
        log_verbose "Found 'cmd/' directory (+3 points)"
        ((score += 3))
        
        #Check if cmd/ has actual binaries (not just examples)
        local cmd_dirs=()
        readarray -t cmd_dirs < <(find "$repo_dir/cmd" -maxdepth 1 -type d -name "[!.]*" 2>/dev/null)
        if [[ ${#cmd_dirs[@]} -gt 0 ]]; then
            log_verbose "Found ${#cmd_dirs[@]} command(s) in cmd/ directory (+1 point)"
            ((score += 1))
        fi
    fi
    
    if [[ -f "$repo_dir/main.go" ]]; then
        log_verbose "Found 'main.go' in root (+2 points)"
        ((score += 2))
    fi
    
    #Check for library patterns - multiple packages without main indicators
    local non_example_dirs=()
    for dir in "${dirs[@]}"; do
        local dir_name=$(basename "$dir")
        if [[ ! "$dir_name" =~ ^(example|examples|demo|demos|test|tests|_example|_examples|\..*|vendor|node_modules)$ ]]; then
            non_example_dirs+=("$dir")
        fi
    done
    
    if [[ ${#non_example_dirs[@]} -gt 2 && ! -f "$repo_dir/main.go" && ! -d "$repo_dir/cmd" ]]; then
        log_verbose "Multiple non-example packages without main indicators (-2 points)"
        ((score -= 2))
    fi
    
    #Check for typical library structure
    if [[ -d "$repo_dir/pkg" || -d "$repo_dir/lib" || -d "$repo_dir/internal" ]]; then
        local lib_dirs=0
        [[ -d "$repo_dir/pkg" ]] && ((lib_dirs++)) && log_verbose "Found 'pkg/' directory (library indicator)"
        [[ -d "$repo_dir/lib" ]] && ((lib_dirs++)) && log_verbose "Found 'lib/' directory (library indicator)"
        [[ -d "$repo_dir/internal" ]] && ((lib_dirs++)) && log_verbose "Found 'internal/' directory (library indicator)"
        
        if [[ $lib_dirs -gt 0 && ! -f "$repo_dir/main.go" && ! -d "$repo_dir/cmd" ]]; then
            log_verbose "Library structure without main entry points (-1 point)"
            ((score -= 1))
        fi
    fi
    
    echo "$score"
}
#-------------------------------------------------------#

#-------------------------------------------------------#
##Check README for CLI indicators
check_readme() {
    local repo_dir="$1"
    local score=0
    local readme_files=()
    
    log_verbose "Analyzing README for CLI indicators..."
    
    #Find README files efficiently
    readarray -t readme_files < <(find "$repo_dir" -maxdepth 1 -type f \( -iname "readme*" \) 2>/dev/null)
    
    #Fallback if no files found
    [[ ${#readme_files[@]} -eq 0 ]] && {
        shopt -s nullglob nocaseglob 2>/dev/null
        readme_files=("$repo_dir"/readme*)
        shopt -u nullglob nocaseglob 2>/dev/null
    }
    
    #Process first README found
    [[ ${#readme_files[@]} -gt 0 && -f "${readme_files[0]}" ]] && {
        local readme_file="${readme_files[0]}"
        log_verbose "Analyzing: ${readme_file#$repo_dir/}"
        
        #Define pattern arrays for efficient matching
        local install_binary_patterns=(
            "go install.*@latest"
            "install.*binary"
            "download.*binary"
            "download.*release"
            "brew install"
            "apt install"
            "install.*globally"
        )
        
        local cli_tool_patterns=(
            "command.line.tool"
            "command line tool"
            "\bcli tool\b"
            "binary"
            "executable"
            "Usage:"
            "Synopsis:"
            "SYNOPSIS"
        )
        
        local library_patterns=(
            "import.*github"
            "go get.*-u"
            "library"
            "package"
            "API"
            "documentation"
            "godoc"
        )
        
        local usage_patterns=(
            "\$ [a-zA-Z0-9_-]+[[:space:]]"
            "bash.*\$"
            "Usage:"
            "Examples?:"
            "\./[a-zA-Z0-9_-]+"
            "command.*example"
        )
        
        #Check for binary installation patterns
        local found_binary_install=false
        for pattern in "${install_binary_patterns[@]}"; do
            if grep -iE "$pattern" "$readme_file" >/dev/null 2>&1; then
                log_verbose "Found binary installation instructions (+2 points)"
                ((score += 2))
                found_binary_install=true
                break
            fi
        done
        
        #Check for CLI tool indicators
        for pattern in "${cli_tool_patterns[@]}"; do
            if grep -iE "$pattern" "$readme_file" >/dev/null 2>&1; then
                log_verbose "Found CLI tool keywords (+1 point)"
                ((score += 1))
                break
            fi
        done
        
        #Check for command usage examples
        for pattern in "${usage_patterns[@]}"; do
            if grep -E "$pattern" "$readme_file" >/dev/null 2>&1; then
                log_verbose "Found command-line usage examples (+1 point)"
                ((score += 1))
                break
            fi
        done
        
        #Check for library indicators (negative points)
        local library_indicators=0
        for pattern in "${library_patterns[@]}"; do
            if grep -iE "$pattern" "$readme_file" >/dev/null 2>&1; then
                ((library_indicators++))
            fi
        done
        
        if [[ $library_indicators -ge 2 && ! $found_binary_install ]]; then
            log_verbose "Strong library indicators in README (-1 point)"
            ((score -= 1))
        fi
    }
    
    echo "$score"
}
#-------------------------------------------------------#

#-------------------------------------------------------#
##Check for binary/executable indicators in files
check_executable_indicators() {
    local repo_dir="$1"
    local score=0
    local go_files=()
    
    log_verbose "Checking for executable indicators in code..."
    
    #Get all .go files efficiently, excluding examples and tests
    readarray -t go_files < <(find "$repo_dir" -name "*.go" -type f ! -path "*/example/*" ! -path "*/examples/*" ! -path "*/demo/*" ! -path "*/demos/*" ! -path "*/_example/*" ! -path "*/_examples/*" ! -name "*_test.go" 2>/dev/null)
    
    [[ ${#go_files[@]} -eq 0 ]] && {
        echo "$score"
        return
    }
    
    #Define CLI library patterns
    local cli_lib_patterns=(
        "flag\."
        "os\.Args"
        "cobra\."
        "cli\."
        "urfave/cli"
        "spf13/cobra"
        "spf13/pflag"
        "kingpin\."
        "alecthomas/kingpin"
        "jessevdk/go-flags"
    )
    
    #Check for CLI library usage in non-example files
    local found_cli_libs=false
    for pattern in "${cli_lib_patterns[@]}"; do
        if printf '%s\n' "${go_files[@]}" | xargs -r grep -l "$pattern" >/dev/null 2>&1; then
            log_verbose "Found CLI library usage: $pattern (+1 point)"
            ((score += 1))
            found_cli_libs=true
            break
        fi
    done
    
    #Check for main function in non-example files
    if printf '%s\n' "${go_files[@]}" | xargs -r grep -l "func main()" >/dev/null 2>&1; then
        log_verbose "Found main() function in non-example files (+1 point)"
        ((score += 1))
    fi
    
    echo "$score"
}
#-------------------------------------------------------#

#-------------------------------------------------------#
##Output results in different formats
output_results() {
    local project_type="$1"
    local confidence="$2" 
    local score="$3"
    local main_packages="$4"
    local dir_score="$5"
    local readme_score="$6"
    local exec_score="$7"
    local original_url="$8"
    
    case "$OUTPUT_FORMAT" in
        "json")
            cat << EOF
{
  "url": "$original_url",
  "type": "$project_type",
  "confidence": "$confidence",
  "score": $score,
  "analysis": {
    "main_packages": $main_packages,
    "directory_score": $dir_score,
    "readme_score": $readme_score,
    "executable_score": $exec_score
  },
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
            ;;
        "simple")
            echo "$project_type"
            ;;
        "human"|*)
            echo
            log_info "=== ANALYSIS RESULTS ==="
            echo "Significant main packages found: $main_packages (×5 = $((main_packages * 5)) points)" >&2
            echo "Directory structure score: $dir_score points" >&2
            echo "README analysis score: $readme_score points" >&2
            echo "Executable indicators score: $exec_score points" >&2
            echo "----------------------------------------" >&2
            echo "Total score: $score points" >&2
            echo >&2
            
            case "$project_type" in
                "cli")
                    echo -e "${GREEN}🔧 RESULT: ${BOLD}${CYAN}CLI TOOL${NC} ${DIM}==> ${CYAN}$original_url${NC}" >&2
                    echo -e "${DIM}Confidence: ${BOLD}${GREEN}$confidence${NC}" >&2
                    ;;
                "library") 
                    echo -e "${BLUE}📚 RESULT: ${BOLD}${MAGENTA}LIBRARY${NC} ${DIM}==> ${CYAN}$original_url${NC}" >&2
                    echo -e "${DIM}Confidence: ${BOLD}${GREEN}$confidence${NC}" >&2
                    ;;
                "unclear")
                    echo -e "${YELLOW}❓ RESULT: ${BOLD}${YELLOW}UNCLEAR${NC} ${DIM}==> ${CYAN}$original_url${NC}" >&2
                    echo -e "${DIM}Confidence: ${BOLD}${YELLOW}$confidence${NC}" >&2
                    echo "Could be either a library or CLI tool. Manual inspection recommended." >&2
                    ;;
            esac
            ;;
    esac
}
#-------------------------------------------------------#

#-------------------------------------------------------#
##Detect
detect_project_type() {
    local input_url="$1"
    local total_score=0
    local url_type
    local processed_url
    
    #Detect URL type
    url_type=$(detect_url_type "$input_url")
    
    case "$url_type" in
        "git")
            processed_url=$(normalize_git_url "$input_url")
            log_info "Detected Git URL: $processed_url"
            ;;
        "archive")
            processed_url=$(normalize_archive_url "$input_url")
            log_info "Detected Archive URL: $processed_url"
            ;;
        *)
            log_error "Unknown URL type: $input_url"
            return $EXIT_ERROR
            ;;
    esac
    
    #Create temporary directory
    TEMP_DIR="$(mktemp -d)"
    local repo_dir="$TEMP_DIR/_REPO_"
    
    #Download/clone based on URL type
    case "$url_type" in
        "git")
            if ! clone_git_repository "$processed_url" "$repo_dir"; then
                return $EXIT_ERROR
            fi
            ;;
        "archive")
            if ! download_and_extract_archive "$processed_url" "$repo_dir"; then
                return $EXIT_ERROR
            fi
            ;;
    esac
    
    #Check if it's actually a Go project
    if [[ ! -f "$repo_dir/go.mod" ]]; then
        local go_files=()
        readarray -t go_files < <(find "$repo_dir" -name "*.go" -type f 2>/dev/null | head -5)
        
        [[ ${#go_files[@]} -eq 0 ]] && {
            # Fallback method
            shopt -s globstar nullglob 2>/dev/null
            go_files=("$repo_dir"/**/*.go "$repo_dir"/*.go)
            shopt -u globstar nullglob 2>/dev/null
            
            [[ ${#go_files[@]} -eq 0 ]] && {
                log_error "Not a Go project (no go.mod or .go files found): $input_url"
                return $EXIT_ERROR
            }
        }
    fi
    
    log_info "Source code acquired successfully"
    
    #Run all checks
    local main_packages=$(check_main_packages "$repo_dir")
    local dir_score=$(check_directory_structure "$repo_dir")
    local readme_score=$(check_readme "$repo_dir")
    local exec_score=$(check_executable_indicators "$repo_dir")
    
    #Calculate total score with weighted main packages
    total_score=$((main_packages * 5 + dir_score + readme_score + exec_score))
    
    #Determine project type and confidence based on score
    local project_type confidence exit_code
    
    if [[ $main_packages -gt 0 ]]; then
        project_type="cli"
        confidence="HIGH"
        exit_code=$EXIT_CLI
    elif [[ $total_score -ge 4 ]]; then
        project_type="cli"
        confidence="MEDIUM"
        exit_code=$EXIT_CLI
    elif [[ $total_score -le -2 ]]; then
        project_type="library"
        confidence="HIGH"
        exit_code=$EXIT_LIBRARY
    elif [[ $total_score -le 0 ]]; then
        project_type="library"
        confidence="MEDIUM"
        exit_code=$EXIT_LIBRARY
    else
        project_type="unclear"
        confidence="LOW"
        exit_code=$EXIT_UNCLEAR
    fi
    
    #Output results in requested format
    output_results "$project_type" "$confidence" "$total_score" \
                  "$main_packages" "$dir_score" "$readme_score" "$exec_score" "$input_url"
    
    return $exit_code
}
#-------------------------------------------------------#

#-------------------------------------------------------#
#Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -q|--quiet)
                QUIET=true
                shift
                ;;
            -j|--json)
                OUTPUT_FORMAT="json"
                shift
                ;;
            -s|--simple)
                OUTPUT_FORMAT="simple"
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -h|--help)
                usage
                ;;
            -*)
                log_error "Unknown option: $1"
                usage
                ;;
            *)
                # This should be the URL
                if [[ -n "$INPUT_URL" ]]; then
                    log_error "Multiple URLs provided. Only one URL is allowed."
                    usage
                fi
                INPUT_URL="$1"
                shift
                ;;
        esac
    done
    
    if [[ -z "$INPUT_URL" ]]; then
        log_error "URL is required"
        usage
    fi
}
#-------------------------------------------------------#

#-------------------------------------------------------#
##Main
main() {
    local INPUT_URL=""
    local exit_code
    
    #Parse arguments
    parse_args "$@"
    
    #Run detection and exit with appropriate code
    detect_project_type "$INPUT_URL"
    exit_code=$?

    #cleanup
    cleanup 2>/dev/null
    find "${SYSTMP}" -path "*/_REPO_" -mmin +2 -mmin -10 -exec rm -rf "{}" \; 2>/dev/null
    find "${SYSTMP}" -type d -name "tmp.*" -empty -mmin +2 -mmin -10 -delete 2>/dev/null
    
    #exit 
    exit $exit_code
}
main "$@"
#-------------------------------------------------------#