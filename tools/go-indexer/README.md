### ℹ️ About
Fetches & Cleans up Go Package Index from [`index.golang.org`](https://index.golang.org).<br>

### 🧰 Usage
```mathematica
❯ go-indexer --help

Go index fetcher from index.golang.org

Usage: go-indexer [OPTIONS]

Options:
      --start-date <DATE>  Start date in YYYY-MM-DD format [default: 2019-01-01] //Any older is useless
      --end-date <DATE>    End date in YYYY-MM-DD format [default: 2025-06-20] //Today
  -o, --output <FILE>      Output file path [default: go_modules_index.jsonl]
      --concurrent <N>     Max concurrent days to process [default: 30] //This is good enough
      --retries <N>        Max retries per request [default: 3]
      --batch-size <N>     Records per batch [default: 2000] //This is the max results returned
      --timeout <SECONDS>  Request timeout in seconds [default: 30]
      --dry-run            Show what would be done without executing
      --resume             Resume from existing partial data
  -v, --verbose            Enable verbose output
      --no-process         Skip post-processing step
  -h, --help               Print help
  -V, --version            Print version

```

### 🛠️ Building
```bash
RUST_TARGET="$(uname -m)-unknown-linux-gnu" #musl is slow
RUSTFLAGS="-C target-feature=+crt-static \
           -C default-linker-libraries=yes \
           -C prefer-dynamic=no \
           -C lto=yes \
           -C debuginfo=none \
           -C strip=symbols \
           -C link-arg=-Wl,--build-id=none \
           -C link-arg=-Wl,--discard-all \
           -C link-arg=-Wl,--strip-all"
           
export RUST_TARGET RUSTFLAGS

cargo build --target "${RUST_TARGET}" \
     --all-features \
     --jobs="$(($(nproc)+1))" \
     --release

"./target/${RUST_TARGET}/release/go-indexer" --help
```