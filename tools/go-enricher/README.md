### ℹ️ About
Enriches Go Package Index from [`deps.dev`](https://deps.dev/).<br>

### 🧰 Usage
```mathematica
❯ go-enricher --help

Enrich Go Index Data

Usage: go-enricher [OPTIONS] [SOURCE]

Arguments:
  [SOURCE]  Single Go module source (e.g., github.com/user/repo)

Options:
  -i, --input <FILE>               Input JSON file containing Go modules
  -o, --output <FILE>              Output file path (stdout if not specified)
      --api-url <URL>              Base API URL for deps.dev [default: https://api.deps.dev/v3/projects/]
      --user-agent <STRING>        User agent string for HTTP requests [default: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"]
  -t, --threads <NUM>              Number of concurrent HTTP requests [default: 30]
  -v, --verbose                    Enable verbose output
  -q, --quiet                      Suppress progress output
      --max-retries <NUM>          Maximum number of retry attempts for failed API requests [default: 2]
      --base-delay-ms <MS>         Base delay in milliseconds for exponential backoff [default: 250]
      --request-timeout <SECONDS>  Request timeout in seconds [default: 10]
      --fast-fail-threshold <NUM>  Stop retrying after this many consecutive failures [default: 10]
  -f, --force                      Force overwrite existing output files
  -h, --help                       Print help
  -V, --version                    Print version

```

### 🛠️ Building
```bash
#! WARNING: gnu causes core dumps due to malloc
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

"./target/${RUST_TARGET}/release/go-enricher" --help
```