#!/usr/bin/env bash

#-------------------------------------------------------#
#Entirely Vibe coded by Claude but tested/verified
#Determines if a Go project is a CLI tool or library from a git URL
#-------------------------------------------------------#

#-------------------------------------------------------#
##Env
set -e
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
##Global Flags
QUIET=false
OUTPUT_FORMAT="human"
VERBOSE=false
##Exit Codes
EXIT_CLI=0
EXIT_LIBRARY=1
EXIT_UNCLEAR=2
EXIT_ERROR=3
##Log Opts
log_info() { [[ "$QUIET" == true ]] || echo -e "${BLUE}[INFO]${NC} $1" >&2; }
log_success() { [[ "$QUIET" == true ]] || echo -e "${GREEN}[SUCCESS]${NC} $1" >&2; }
log_warning() { [[ "$QUIET" == true ]] || echo -e "${YELLOW}[WARNING]${NC} $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_verbose() { [[ "$VERBOSE" == true ]] && echo -e "${BLUE}[VERBOSE]${NC} $1" >&2; }
##Cleanup Func
cleanup() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        log_verbose "Cleaning up temporary directory: $TEMP_DIR"
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup EXIT

#-------------------------------------------------------#
##Usage/Help
usage() {
    cat << EOF
Usage: $0 [OPTIONS] <git-url>

DESCRIPTION:
  Detects whether a Go project is a CLI tool or library by analyzing its structure,
  code patterns, and documentation.

OPTIONS:
  -q, --quiet         Suppress progress messages (only output result)
  -j, --json          Output result in JSON format
  -s, --simple        Output simple format: 'cli', 'library', or 'unclear'
  -v, --verbose       Show detailed analysis information
  -h, --help          Show this help message

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
  $0 --json https://github.com/gin-gonic/gin
  
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
##Normalize URLs
normalize_git_url() {
    local url="$1"
    
    # Add https:// if missing
    if [[ ! "$url" =~ ^https?:// ]]; then
        url="https://$url"
    fi
    
    # Ensure .git suffix for cloning
    if [[ ! "$url" =~ \.git$ ]]; then
        url="$url.git"
    fi
    
    echo "$url"
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
    local git_url="$8"
    
    case "$OUTPUT_FORMAT" in
        "json")
            cat << EOF
{
  "url": "$git_url",
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
                    log_success "🔧 RESULT: CLI TOOL"
                    echo "Confidence: $confidence" >&2
                    ;;
                "library") 
                    log_success "📚 RESULT: LIBRARY"
                    echo "Confidence: $confidence" >&2
                    ;;
                "unclear")
                    log_warning "❓ RESULT: UNCLEAR"
                    echo "Confidence: $confidence" >&2
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
    local git_url="$1"
    local total_score=0
    
    log_info "Analyzing Go project: $git_url"
    
    #Create temporary directory
    TEMP_DIR="$(mktemp -d)"
    local repo_dir="$TEMP_DIR/repo"
    
    #Clone
    log_info "Cloning repository..."
    if ! git clone --depth="1" --filter="blob:none" --quiet "$git_url" "$repo_dir" 2>/dev/null; then
        log_error "Failed to clone repository: $git_url"
        return $EXIT_ERROR
    fi
    
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
                log_error "Not a Go project (no go.mod or .go files found)"
                return $EXIT_ERROR
            }
        }
    fi
    
    log_info "Repository cloned successfully"
    
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
                  "$main_packages" "$dir_score" "$readme_score" "$exec_score" "$git_url"
    
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
                # This should be the git URL
                if [[ -n "$GIT_URL" ]]; then
                    log_error "Multiple URLs provided. Only one URL is allowed."
                    usage
                fi
                GIT_URL="$1"
                shift
                ;;
        esac
    done
    
    if [[ -z "$GIT_URL" ]]; then
        log_error "Git URL is required"
        usage
    fi
}
#-------------------------------------------------------#

#-------------------------------------------------------#

##Main
main() {
    local GIT_URL=""
    
    # Parse arguments
    parse_args "$@"
    
    local normalized_url=$(normalize_git_url "$GIT_URL")
    
    # Check if required tools are available
    if ! command -v git >/dev/null 2>&1; then
        log_error "git is required but not installed"
        exit $EXIT_ERROR
    fi
    
    # Run detection and exit with appropriate code
    detect_project_type "$normalized_url"
    exit $?
}
main "$@"
#-------------------------------------------------------#
