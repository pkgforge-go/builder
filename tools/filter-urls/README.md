### ℹ️ About
Remove URLs from files based on HTTP status codes.<br>

### 🧰 Usage
```mathematica
❯ filter-urls --help

Remove URLs from files based on HTTP status codes

Usage: filter-urls [OPTIONS] [input]

Arguments:
  [input]  Input file (or stdin if not provided)

Options:
  -c, --concurrency <NUM>        Number of concurrent requests [default: 10]
  -i, --in-place                 Edit file in place
  -j, --json                     Output JSON format
  -p, --pretty                   Pretty table output
  -m, --method <METHOD>          HTTP method to use [default: HEAD]
  -o, --output <FILE>            Output file path
  -q, --quiet                    Quiet mode - no stdout output
  -r, --retry                    Retry on connection errors
  -f, --force-retry              Force retry with exponential backoff (max 3 attempts)
  -s, --status-code <CODES>      Status codes to filter (comma-separated) [default: 404]
  -u, --user-agent <USER_AGENT>  User agent string to use for requests [default: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15"]
  -v, --verbose                  Verbose output
  -h, --help                     Print help
  -V, --version                  Print version

```

### 🛠️ Building
```bash
RUST_TARGET="$(uname -m)-unknown-linux-musl"
RUSTFLAGS="-C target-feature=+crt-static \
           -C link-self-contained=yes \
           -C default-linker-libraries=yes \
           -C prefer-dynamic=no \
           -C lto=yes \
           -C debuginfo=none \
           -C strip=symbols \
           -C link-arg=-Wl,--build-id=none \
           -C link-arg=-Wl,--discard-all \
           -C link-arg=-Wl,--strip-all"
           
export RUST_TARGET RUSTFLAGS
rustup target add "${RUST_TARGET}"

cargo build --target "${RUST_TARGET}" \
     --all-features \
     --jobs="$(($(nproc)+1))" \
     --release

"./target/${RUST_TARGET}/release/filter-urls" --help
```