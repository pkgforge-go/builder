### ℹ️ About
Detect if a Go Package is CLI.<br>

### 🧰 Usage
```mathematica
❯ go-detector --help

Usage: go-detector [OPTIONS]

Options:
  -goproxy string
        Download and analyze Go module from proxy
  -input string
        File containing list of URLs/modules to process (one per line)
  -json
        Output in JSON format
  -local string
        Analyze local project path
  -proxy-url string
        Go proxy URL (default "https://proxy.golang.org")
  -q    Quiet mode - only exit codes
  -remote string
        Download and analyze remote archive (zip/tar.gz)
  -v    Verbose output (ignored in JSON mode)
  -workers int
        Number of parallel workers (default 20)
```

### 🛠️ Building
```bash
go mod init "github.com/pkgforge-go/builder/go-detector"
go mod tidy -v

export CGO_ENABLED="0"
export GOARCH="amd64"
export GOOS="linux"

go build -a -v -x -trimpath \
         -buildvcs="false" \
         -ldflags="-s -w -buildid= -extldflags '-s -w -Wl,--build-id=none'" \
         -o "./go-detector"

"./go-detector" --help
```