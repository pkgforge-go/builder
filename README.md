<div align="center">

[discord-shield]: https://img.shields.io/discord/1313385177703256064?logo=%235865F2&label=discord
[discord-url]: https://discord.gg/djJUs48Zbu
[doc-shield]: https://img.shields.io/badge/docs-soar.qaidvoid.dev-blue
[doc-url]: https://soar.qaidvoid.dev
[issues-shield]: https://img.shields.io/github/issues/pkgforge-go/builder.svg
[issues-url]: https://github.com/pkgforge-go/builder/issues
[license-shield]: https://img.shields.io/github/license/pkgforge-go/builder.svg
[license-url]: https://github.com/pkgforge-go/builder/blob/main/LICENSE
[stars-shield]: https://img.shields.io/github/stars/pkgforge-go/builder.svg
[stars-url]: https://github.com/pkgforge-go/builder/stargazers

[![Discord][discord-shield]][discord-url]
[![Documentation][doc-shield]][doc-url]
[![Issues][issues-shield]][issues-url]
[![License: MIT][license-shield]][license-url]
[![Stars][stars-shield]][stars-url]

</div>

<p align="center">
    <a href="https://soar.qaidvoid.dev/installation">
        <img src="https://soar.pkgforge.dev/gif?version=v0.6.3" alt="soar-list" width="750">
    </a><br>
</p>

<h4 align="center">
  <a href="https://soar.qaidvoid.dev">📘 Documentation</a> |
  <a href="https://docs.pkgforge.dev">🔮 PackageForge</a>
</h4>

<p align="center">
    Soar is a Fast, Modern, Bloat-Free Distro-Independent Package Manager that <a href="https://docs.pkgforge.dev/soar/comparisons"> <i>Just Works</i></a><br>
    Supports <a href="https://docs.pkgforge.dev/formats/binaries/static">Static Binaries</a>, <a href="https://docs.pkgforge.dev/formats/packages/appimage">AppImages</a>, and other <a href="https://docs.pkgforge.dev/formats/packages">Portable formats</a> on any <a href="https://docs.pkgforge.dev/repositories/soarpkgs/faq#portability"><i>*Unix-based</i> Distro</a>
</p>


## ℹ️ About
This repo, scrapes Go Packages from variety of sources & builds them as Statically Linked relocatable binaries for `aarch64-Linux`, `loongarch64-Linux`, `riscv64-Linux` & `x86_64-Linux`.<br>
The [build script](https://github.com/pkgforge-go/builder/blob/main/scripts/builder.sh) uses [Zig](https://zig.guide/working-with-c/zig-cc/) to compile the packages on [Github Actions](https://github.com/pkgforge-go/builder/actions) & then uploads the artifacts to [ghcr.io](https://github.com/orgs/pkgforge-go/packages?repo_name=builder) using [Oras](https://github.com/oras-project/oras).<br>
All of which are downloadable & installable with soar by adding `pkgforge-go` as an [external repo](https://docs.pkgforge.dev/repositories/external/pkgforge-go).

## 🏗️ Build Constraints
- [X] Must have a source published publicly, preferably [`Github`](https://github.com/search?q=lang%3Ago&type=repositories)
- [X] [Must be CLI (No library)](https://pkg.go.dev/)
- [X] Statically Linked
- [X] [CGO](https://pkg.go.dev/cmd/cgo): `CGO_ENABLED=1 CGO_CFLAGS=-O2 -flto=auto -fPIE -fpie -static -w -pipe`
- [X] [Buildmode PIE](https://pkg.go.dev/cmd/go#hdr-Build_modes): `-buildmode=pie`
- [X] Stripped: `-extldflags -s -w -static-pie -Wl,--build-id=none`
- [X] Updated: Packages older than last year i.e `date -d 'last year' '+%Y-01-01'` are dropped.
- [X] Little/No Dependency on system libraries: Crates depending on system libraries will simply fail.

```bash
  ==> CC: zig cc -target ${target_triplet}
  ==> CGO_CFLAGS: -O2 -flto=auto -fPIE -fpie -static -w -pipe
  ==> CGO_ENABLED: 1
  ==> CXX: zig c++ -target ${target_triplet}
  ==> GOARCH: $(uname -m)
  ==> GOOS: linux
  ==> LDFLAGS: -s -w -buildid= -linkmode=external
  ==> EXT_LDFLAGS: -s -w -static-pie -Wl,--build-id=none
  ==> GO_TAGS: netgo,osusergo
  ==> GO_BUILD: go build -a -v -x -trimpath -buildmode="pie" -buildvcs="false"
```

## 🤖 Hosts & 🐹 Targets
| 🤖 `HOST_TRIPLET` | 🐹 `GO_TARGET` |
|----------------|---------------|
| `aarch64-Linux` | `linux/arm64` |
| `loongarch64-Linux` | `linux/loong64` |
| `riscv64-Linux` | `linux/riscv64` |
| `x86_64-Linux` | `linux/amd64` |

## 🧰 Stats
> [!NOTE]
> - ℹ️ It is usual for most workflow run to `fail` since it's rare a package builds for ALL `hosts`<br>
> - 🗄️ Table of Packages (Sorted by Rank): https://github.com/pkgforge-go/builder/blob/main/data/PKG_INFO.md<br>
> - 📜 List of Packages (Tried Building): https://github.com/pkgforge-go/builder/blob/main/data/QUEUE_LIST.txt
> - 📜 List of Packages (Actually Built): https://github.com/pkgforge-go/builder/blob/main/data/CACHE_LIST.txt
> - A single Package may provide several `executables`, i.e they are counted individually per `host`

| Source 🗃️ | Total Packages 📦 |
|------------|-------------------|
| 🐹 [**Packages (`Total Scraped`)**](https://github.com/pkgforge-go/builder/blob/main/data/REPO_DUMP.json) | [![Packages](https://img.shields.io/badge/dynamic/json?url=https://raw.githubusercontent.com/pkgforge-go/builder/refs/heads/main/data/COUNT.json&query=$[0].total&label=&color=crimson&style=flat)](#) |
| 🐹 [**Packages (`CLI Only`)**](https://github.com/pkgforge-go/builder/blob/main/data/PKGS_CLI_ONLY.json) | [![Packages](https://img.shields.io/badge/dynamic/json?url=https://raw.githubusercontent.com/pkgforge-go/builder/refs/heads/main/data/COUNT.json&query=$[1].total&label=&color=orange&style=flat)](#) |
| 🐹 [**Packages (`Built`)**](https://github.com/pkgforge-go/builder/blob/main/data/PKGS_BUILT.json) | [![Packages](https://img.shields.io/badge/dynamic/json?url=https://raw.githubusercontent.com/pkgforge-go/builder/refs/heads/main/data/COUNT.json&query=$[3].total&label=&color=blue&style=flat)](#) |
| 🐹 [**Packages (`Queued`)**](https://github.com/pkgforge-go/builder/blob/main/data/QUEUE_LIST.txt) | [![Packages](https://img.shields.io/badge/dynamic/json?url=https://raw.githubusercontent.com/pkgforge-go/builder/refs/heads/main/data/COUNT.json&query=$[4].total&label=&color=coral&style=flat)](#) |
| 🐹 [**Packages (`aarch64-Linux`)**](https://github.com/pkgforge-go/builder/blob/main/data/aarch64-Linux.json) | [![Packages](https://img.shields.io/badge/dynamic/json?url=https://raw.githubusercontent.com/pkgforge-go/builder/refs/heads/main/data/COUNT.json&query=$[5].total&label=&color=green&style=flat)](#) |
| 🐹 [**Packages (`loongarch64-Linux`)**](https://github.com/pkgforge-go/builder/blob/main/data/loongarch64-Linux.json) | [![Packages](https://img.shields.io/badge/dynamic/json?url=https://raw.githubusercontent.com/pkgforge-go/builder/refs/heads/main/data/COUNT.json&query=$[6].total&label=&color=green&style=flat)](#) |
| 🐹 [**Packages (`riscv64-Linux`)**](https://github.com/pkgforge-go/builder/blob/main/data/riscv64-Linux.json) | [![Packages](https://img.shields.io/badge/dynamic/json?url=https://raw.githubusercontent.com/pkgforge-go/builder/refs/heads/main/data/COUNT.json&query=$[7].total&label=&color=green&style=flat)](#) |
| 🐹 [**Packages (`x86_64-Linux`)**](https://github.com/pkgforge-go/builder/blob/main/data/x86_64-Linux.json) | [![Packages](https://img.shields.io/badge/dynamic/json?url=https://raw.githubusercontent.com/pkgforge-go/builder/refs/heads/main/data/COUNT.json&query=$[8].total&label=&color=green&style=flat)](#) |
| 🐹 [**Packages (`Success Rate`)**](https://github.com/pkgforge-go/builder/blob/main/data/QUEUE_LIST.txt) | [![Packages](https://img.shields.io/badge/dynamic/json?url=https://raw.githubusercontent.com/pkgforge-go/builder/refs/heads/main/data/COUNT.json&query=$[9].total&label=&color=olive&style=flat)](#) <sup>**`%`**</sup> |
| 🐹 [**Packages (`Total Built`)**](https://github.com/orgs/pkgforge-go/packages?repo_name=builder) | [![Packages](https://img.shields.io/badge/dynamic/json?url=https://raw.githubusercontent.com/pkgforge-go/builder/refs/heads/main/data/COUNT.json&query=$[10].total&label=&color=teal&style=flat)](#) |

## 🔒 Security
- Package Sources are recorded & embedded in metadata.
- CI/CD run on [Github Actions](https://docs.github.com/en/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions)
- Build Logs are viewable using `soar log ${PKG_NAME}`
- Build Src is downloadable by downloading: [`{GHCR_PKG}-srcbuild-${BUILD_ID}`](https://github.com/orgs/pkgforge-go/packages?tab=packages&q=srcbuild)
- [Artifact Attestation](https://github.com/pkgforge-go/builder/attestations) & [Build Provenance](https://github.com/pkgforge-go/builder/attestations) are created/updated per build.

## 🟢 Workflow
![image](https://github.com/user-attachments/assets/9d59fb69-99f5-4a26-9ada-4f48c892c1f9)
```mermaid
graph TD
    A[Scraper] -->|PKGS_LIST| B[PKGS_DUMP.json]
    B --> C[GitHub Repository<br/>pkgforge-go/builder]
    
    C --> D[Build Script<br/>builder.sh]
    D --> E[Go+Zig]
    
    E --> F1[aarch64-Linux<br/>Static Binary]
    E --> F2[loongarch64-Linux<br/>Static Binary] 
    E --> F3[riscv64-Linux<br/>Static Binary]
    E --> F4[x86_64-Linux<br/>Static Binary]
    
    F1 --> G[GitHub Actions<br/>Build Pipeline]
    F2 --> G
    F3 --> G
    F4 --> G
    
    G --> H[Oras Tool]
    H --> I[ghcr.io<br/>Container Registry]
    
    I --> J[External Repository<br/>pkgforge-go]
    J --> K[Soar Package Manager]
    K --> L[End Users]
    
    style A fill:#ff6b6b,stroke:#333,stroke-width:2px,color:#fff
    style I fill:#4ecdc4,stroke:#333,stroke-width:2px,color:#fff
    style K fill:#45b7d1,stroke:#333,stroke-width:2px,color:#fff
    style L fill:#96ceb4,stroke:#333,stroke-width:2px,color:#fff
    
    classDef buildProcess fill:#ffd93d,stroke:#333,stroke-width:2px
    class D,E,G,H buildProcess
    
    classDef binary fill:#ff8fab,stroke:#333,stroke-width:2px,color:#fff
    class F1,F2,F3,F4 binary
```
