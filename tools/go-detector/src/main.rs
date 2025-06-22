use anyhow::{anyhow, Result};
use clap::{Arg, Command as ClapCommand};
use indicatif::{ProgressBar, ProgressStyle};
use rayon::prelude::*;
use regex::Regex;
use reqwest;
use serde_json::json;
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use tempfile::TempDir;
use tokio;

#[derive(Debug, Clone, Copy)]
enum OutputFormat {
    Human,
    Json,
    Simple,
}

#[derive(Debug, Clone, Copy)]
enum ProjectType {
    Cli,
    Library,
    Unclear,
}

impl ProjectType {
    fn as_str(&self) -> &'static str {
        match self {
            ProjectType::Cli => "cli",
            ProjectType::Library => "library",
            ProjectType::Unclear => "unclear",
        }
    }

    fn exit_code(&self) -> i32 {
        match self {
            ProjectType::Cli => 0,
            ProjectType::Library => 1,
            ProjectType::Unclear => 2,
        }
    }
}

#[derive(Debug)]
struct Analysis {
    main_packages: usize,
    directory_score: i32,
    readme_score: i32,
    executable_score: i32,
    go_mod_score: i32,
    binary_score: i32,
    total_score: i32,
    project_type: ProjectType,
    confidence: &'static str,
    details: Vec<String>,
}

#[derive(Debug)]
struct GoFileInfo {
    path: PathBuf,
    package_name: String,
    has_main_func: bool,
    imports: Vec<String>,
    has_cli_patterns: bool,
}

struct Detector {
    quiet: bool,
    verbose: bool,
    output_format: OutputFormat,
    cli_patterns: Regex,
    main_package_regex: Regex,
    import_regex: Regex,
}

impl Detector {
    fn new(quiet: bool, verbose: bool, output_format: OutputFormat) -> Result<Self> {
        let cli_patterns = Regex::new(
            r"(?i)(flag\.|os\.Args|cobra\.|spf13/cobra|urfave/cli|kingpin|pflag|cli\.App|\.Parse\(\)|\.String\(\)|\.Int\(\)|\.Bool\(\))",
        )?;
        let main_package_regex = Regex::new(r"^\s*package\s+main\s*$")?;
        let import_regex =
            Regex::new(r#"^\s*(?:import\s+(?:\(|"([^"]+)"|`([^`]+)`)|"([^"]+)"|`([^`]+)`)"#)?;

        Ok(Self {
            quiet,
            verbose,
            output_format,
            cli_patterns,
            main_package_regex,
            import_regex,
        })
    }

    fn log_info(&self, msg: &str) {
        if !self.quiet {
            eprintln!("\x1b[34m[INFO]\x1b[0m {}", msg);
        }
    }

    fn log_verbose(&self, msg: &str) {
        if self.verbose && !self.quiet {
            eprintln!("\x1b[34m[VERBOSE]\x1b[0m {}", msg);
        }
    }

    fn log_error(&self, msg: &str) {
        eprintln!("\x1b[31m[ERROR]\x1b[0m {}", msg);
    }

    fn detect_url_type(&self, url: &str) -> Result<(&str, String)> {
        let url = url.trim();

        if url.ends_with(".tar.gz")
            || url.ends_with(".tgz")
            || url.ends_with(".zip")
            || url.contains("/archive/")
            || url.contains("/tarball/")
            || url.contains("/releases/download/")
        {
            let normalized = if url.starts_with("http") {
                url.to_string()
            } else {
                format!("https://{}", url)
            };
            Ok(("archive", normalized))
        } else {
            let mut normalized = if url.starts_with("http") {
                url.to_string()
            } else {
                format!("https://{}", url)
            };
            if !normalized.ends_with(".git") && !normalized.contains("github.com") {
                normalized.push_str(".git");
            }
            Ok(("git", normalized))
        }
    }

    async fn download_archive(&self, url: &str, extract_dir: &Path) -> Result<()> {
        self.log_info(&format!("Downloading archive: {}", url));

        let pb = if !self.quiet {
            let pb = ProgressBar::new_spinner();
            pb.set_style(ProgressStyle::default_spinner().template("{spinner:.blue} {msg}")?);
            pb.set_message("Downloading...");
            Some(pb)
        } else {
            None
        };

        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(60))
            .build()?;

        let response = client.get(url).send().await?;
        if !response.status().is_success() {
            return Err(anyhow!("Failed to download: HTTP {}", response.status()));
        }

        let bytes = response.bytes().await?;

        if let Some(pb) = &pb {
            pb.set_message("Extracting...");
        }

        let archive_path = extract_dir.join("archive");
        fs::write(&archive_path, &bytes)?;

        // Detect archive format from content or extension
        let extract_success = if url.ends_with(".zip") || self.is_zip_file(&archive_path)? {
            self.try_extract_zip(&archive_path, extract_dir).is_ok()
        } else {
            self.try_extract_tar(&archive_path, extract_dir).is_ok()
        };

        fs::remove_file(&archive_path).ok();

        if let Some(pb) = pb {
            pb.finish_with_message("Done");
        }

        if extract_success {
            Ok(())
        } else {
            Err(anyhow!("Failed to extract archive"))
        }
    }

    fn is_zip_file(&self, path: &Path) -> Result<bool> {
        let bytes = fs::read(path)?;
        Ok(bytes.len() >= 4 && &bytes[0..4] == b"PK\x03\x04")
    }

    fn try_extract_tar(&self, archive_path: &Path, extract_dir: &Path) -> Result<()> {
        let output = Command::new("tar")
            .args(&[
                "-xzf",
                archive_path.to_str().unwrap(),
                "--strip-components=1",
            ])
            .current_dir(extract_dir)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()?;

        if output.success() {
            Ok(())
        } else {
            // Try without compression flag
            let output = Command::new("tar")
                .args(&[
                    "-xf",
                    archive_path.to_str().unwrap(),
                    "--strip-components=1",
                ])
                .current_dir(extract_dir)
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()?;

            if output.success() {
                Ok(())
            } else {
                Err(anyhow!("tar extraction failed"))
            }
        }
    }

    fn try_extract_zip(&self, archive_path: &Path, extract_dir: &Path) -> Result<()> {
        let output = Command::new("unzip")
            .args(&[
                "-q",
                "-o",
                archive_path.to_str().unwrap(),
                "-d",
                extract_dir.to_str().unwrap(),
            ])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()?;

        if output.success() {
            self.handle_single_directory_extraction(extract_dir)?;
            Ok(())
        } else {
            Err(anyhow!("unzip extraction failed"))
        }
    }

    fn handle_single_directory_extraction(&self, extract_dir: &Path) -> Result<()> {
        let entries: Vec<_> = fs::read_dir(extract_dir)?
            .filter_map(|e| e.ok())
            .filter(|e| e.file_type().map(|t| t.is_dir()).unwrap_or(false))
            .collect();

        if entries.len() == 1 {
            let source = entries[0].path();
            self.move_directory_contents(&source, extract_dir)?;
            fs::remove_dir_all(&source).ok();
        }
        Ok(())
    }

    fn move_directory_contents(&self, source: &Path, dest: &Path) -> Result<()> {
        for entry in fs::read_dir(source)? {
            let entry = entry?;
            let dest_path = dest.join(entry.file_name());
            if entry.file_type()?.is_dir() {
                fs::rename(entry.path(), dest_path)?;
            } else {
                fs::copy(entry.path(), dest_path)?;
                fs::remove_file(entry.path()).ok();
            }
        }
        Ok(())
    }

    fn clone_git(&self, url: &str, clone_dir: &Path) -> Result<()> {
        self.log_info(&format!("Cloning repository: {}", url));

        let pb = if !self.quiet {
            let pb = ProgressBar::new_spinner();
            pb.set_style(ProgressStyle::default_spinner().template("{spinner:.blue} {msg}")?);
            pb.set_message("Cloning...");
            Some(pb)
        } else {
            None
        };

        // Use shallow clone for better performance
        let output = Command::new("git")
            .args(&[
                "clone",
                "--depth=1",
                "--filter=blob:none",
                "--quiet",
                url,
                clone_dir.to_str().unwrap(),
            ])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()?;

        if let Some(pb) = pb {
            pb.finish_with_message("Done");
        }

        if output.success() {
            Ok(())
        } else {
            Err(anyhow!("Git clone failed"))
        }
    }

    fn analyze_go_file(&self, path: &Path) -> Result<GoFileInfo> {
        let content = fs::read_to_string(path)?;
        let lines: Vec<&str> = content.lines().collect();

        let mut package_name = String::new();
        let mut imports = Vec::new();
        let mut has_main_func = false;
        let has_cli_patterns = self.cli_patterns.is_match(&content);

        for line in &lines {
            if package_name.is_empty() && self.main_package_regex.is_match(line) {
                package_name = "main".to_string();
            } else if package_name.is_empty() && line.trim().starts_with("package ") {
                package_name = line
                    .trim()
                    .strip_prefix("package ")
                    .unwrap_or("")
                    .trim()
                    .to_string();
            }

            if line.contains("func main(") {
                has_main_func = true;
            }

            // Extract imports
            if let Some(caps) = self.import_regex.captures(line) {
                for i in 1..=4 {
                    if let Some(import) = caps.get(i) {
                        imports.push(import.as_str().to_string());
                        break;
                    }
                }
            }
        }

        Ok(GoFileInfo {
            path: path.to_path_buf(),
            package_name,
            has_main_func,
            imports,
            has_cli_patterns,
        })
    }

    fn find_go_files(&self, dir: &Path) -> Result<Vec<PathBuf>> {
        let mut go_files = Vec::new();
        self.find_go_files_recursive(dir, &mut go_files, 0)?;
        Ok(go_files)
    }

    fn find_go_files_recursive(
        &self,
        dir: &Path,
        files: &mut Vec<PathBuf>,
        depth: usize,
    ) -> Result<()> {
        // Limit recursion depth to avoid issues
        if depth > 10 {
            return Ok(());
        }

        for entry in fs::read_dir(dir)? {
            let entry = entry?;
            let path = entry.path();

            if path.is_dir() && !self.is_ignored_dir(&path) {
                self.find_go_files_recursive(&path, files, depth + 1)?;
            } else if path.extension().map_or(false, |ext| ext == "go") && !self.is_test_file(&path)
            {
                files.push(path);
            }
        }
        Ok(())
    }

    fn is_ignored_dir(&self, path: &Path) -> bool {
        if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
            matches!(
                name,
                "vendor"
                    | "node_modules"
                    | ".git"
                    | ".github"
                    | ".gitignore"
                    | "testdata"
                    | "tests"
                    | "_test"
                    | "docs"
                    | "documentation"
                    | "examples"
            )
        } else {
            false
        }
    }

    fn is_test_file(&self, path: &Path) -> bool {
        path.file_name()
            .and_then(|n| n.to_str())
            .map_or(false, |name| name.ends_with("_test.go"))
    }

    fn is_example_file(&self, path: &Path) -> bool {
        let path_str = path.to_string_lossy().to_lowercase();
        path_str.contains("/example")
            || path_str.contains("/demo")
            || path_str.contains("/sample")
            || path_str.contains("_example.go")
    }

    fn check_main_packages(&self, repo_dir: &Path) -> Result<(usize, Vec<String>)> {
        self.log_verbose("Checking for main packages...");

        let go_files = self.find_go_files(repo_dir)?;

        // Parallel processing for better performance
        let file_infos: Vec<_> = go_files
            .par_iter()
            .filter_map(|file| {
                if self.is_example_file(file) {
                    return None;
                }
                self.analyze_go_file(file).ok()
            })
            .collect();

        let mut main_count = 0;
        let mut details = Vec::new();

        for info in file_infos {
            if info.package_name == "main" && info.has_main_func {
                let relative_path = info
                    .path
                    .strip_prefix(repo_dir)
                    .unwrap_or(&info.path)
                    .to_string_lossy();

                self.log_verbose(&format!(
                    "Found main package with main(): {}",
                    relative_path
                ));
                details.push(format!("Main package: {}", relative_path));
                main_count += 1;

                // Use CLI patterns for additional scoring
                if info.has_cli_patterns {
                    details.push(format!("CLI patterns detected in: {}", relative_path));
                }

                for import in &info.imports {
                    if import.contains("cobra")
                        || import.contains("urfave/cli")
                        || import.contains("kingpin")
                    {
                        details.push(format!("CLI framework import: {}", import));
                    }
                }
            }
        }
        Ok((main_count, details))
    }

    fn check_directory_structure(&self, repo_dir: &Path) -> (i32, Vec<String>) {
        self.log_verbose("Analyzing directory structure...");
        let mut score = 0;
        let mut details = Vec::new();

        // Check for CLI-specific directories
        if repo_dir.join("cmd").is_dir() {
            self.log_verbose("Found 'cmd/' directory (+4 points)");
            score += 4;
            details.push("CLI structure: cmd/ directory".to_string());
        }

        if repo_dir.join("main.go").is_file() {
            self.log_verbose("Found 'main.go' in root (+3 points)");
            score += 3;
            details.push("Entry point: main.go in root".to_string());
        }

        // Check for CLI binary directories
        if repo_dir.join("bin").is_dir() {
            score += 1;
            details.push("Binary directory: bin/".to_string());
        }

        // Check for library-specific structure
        let has_lib_dirs = repo_dir.join("pkg").is_dir()
            || repo_dir.join("lib").is_dir()
            || repo_dir.join("internal").is_dir();

        if has_lib_dirs && !repo_dir.join("main.go").exists() && !repo_dir.join("cmd").exists() {
            self.log_verbose("Library structure without main entry points (-2 points)");
            score -= 2;
            details.push("Library structure: pkg/lib/internal without main".to_string());
        }

        // Check for Makefile or build scripts
        if repo_dir.join("Makefile").exists() || repo_dir.join("build.sh").exists() {
            score += 1;
            details.push("Build system present".to_string());
        }

        (score, details)
    }

    fn check_go_mod(&self, repo_dir: &Path) -> (i32, Vec<String>) {
        self.log_verbose("Analyzing go.mod...");
        let mut score = 0;
        let mut details = Vec::new();

        let go_mod_path = repo_dir.join("go.mod");
        if !go_mod_path.exists() {
            return (score, details);
        }

        if let Ok(content) = fs::read_to_string(&go_mod_path) {
            // Check for CLI frameworks
            let cli_deps = [
                "github.com/spf13/cobra",
                "github.com/urfave/cli",
                "github.com/spf13/pflag",
                "gopkg.in/alecthomas/kingpin",
                "github.com/jessevdk/go-flags",
            ];

            for dep in &cli_deps {
                if content.contains(dep) {
                    score += 2;
                    details.push(format!("CLI dependency: {}", dep));
                    self.log_verbose(&format!("Found CLI dependency: {} (+2 points)", dep));
                }
            }

            // Check module name pattern
            if let Some(line) = content.lines().find(|l| l.starts_with("module ")) {
                let module_name = line.strip_prefix("module ").unwrap_or("").trim();
                if module_name.ends_with("/cmd")
                    || module_name.contains("-cli")
                    || module_name.contains("tool")
                {
                    score += 1;
                    details.push("CLI-pattern module name".to_string());
                }
            }
        }

        (score, details)
    }

    fn check_readme(&self, repo_dir: &Path) -> (i32, Vec<String>) {
        self.log_verbose("Analyzing README...");
        let mut score = 0;
        let mut details = Vec::new();

        let readme_patterns = [
            "readme.md",
            "README.md",
            "readme.txt",
            "README.txt",
            "readme",
            "README",
        ];

        for pattern in &readme_patterns {
            let readme_path = repo_dir.join(pattern);
            if readme_path.is_file() {
                if let Ok(content) = fs::read_to_string(&readme_path) {
                    let content_lower = content.to_lowercase();

                    // Installation patterns
                    if content_lower.contains("go install") && content_lower.contains("@latest") {
                        self.log_verbose("Found binary installation instructions (+3 points)");
                        score += 3;
                        details.push("Installation: go install command".to_string());
                    }

                    if content_lower.contains("go get") && !content_lower.contains("import") {
                        score += 2;
                        details.push("Installation: go get command".to_string());
                    }

                    // CLI keywords
                    let cli_keywords = [
                        "cli tool",
                        "command line",
                        "command-line",
                        "terminal",
                        "console",
                    ];
                    for keyword in &cli_keywords {
                        if content_lower.contains(keyword) {
                            score += 1;
                            details.push(format!("CLI keyword: {}", keyword));
                            break;
                        }
                    }

                    // Usage examples
                    if Regex::new(r"\$ [a-zA-Z0-9_-]+\s")
                        .unwrap()
                        .is_match(&content)
                    {
                        self.log_verbose("Found command-line usage examples (+2 points)");
                        score += 2;
                        details.push("Usage: Command-line examples".to_string());
                    }

                    // Options/flags documentation
                    if content.contains("--")
                        || content.contains("flags:")
                        || content.contains("options:")
                    {
                        score += 1;
                        details.push("Documentation: CLI flags/options".to_string());
                    }

                    // Library indicators
                    if content_lower.contains("import") && content_lower.contains("package") {
                        score -= 1;
                        details.push("Library indicator: import examples".to_string());
                    }
                }
                break;
            }
        }

        (score, details)
    }

    fn check_executable_indicators(&self, repo_dir: &Path) -> (i32, Vec<String>) {
        self.log_verbose("Checking for executable indicators...");
        let mut score = 0;
        let mut details = Vec::new();

        let go_files = self.find_go_files(repo_dir).unwrap_or_default();
        let mut cli_patterns_found = HashSet::new();

        for file in go_files {
            if self.is_example_file(&file) || self.is_test_file(&file) {
                continue;
            }

            if let Ok(info) = self.analyze_go_file(&file) {
                // Use the has_cli_patterns field
                if info.has_cli_patterns && !cli_patterns_found.contains("cli_patterns") {
                    self.log_verbose("Found CLI patterns in file (+2 points)");
                    score += 2;
                    details.push("CLI patterns detected in source".to_string());
                    cli_patterns_found.insert("cli_patterns");
                }

                // Use imports for specific framework detection
                for import in &info.imports {
                    let framework = if import.contains("cobra") {
                        "Cobra CLI framework"
                    } else if import.contains("urfave/cli") {
                        "Urfave CLI framework"
                    } else if import.contains("kingpin") {
                        "Kingpin CLI framework"
                    } else if import.contains("flag") {
                        "Standard flag package"
                    } else {
                        continue;
                    };

                    if !cli_patterns_found.contains(framework) {
                        self.log_verbose(&format!("Found {}: {} (+1 point)", framework, import));
                        score += 1;
                        details.push(format!("CLI framework: {}", framework));
                        cli_patterns_found.insert(framework);
                    }
                }
            }
        }

        (score, details)
    }

    fn check_binary_indicators(&self, repo_dir: &Path) -> (i32, Vec<String>) {
        self.log_verbose("Checking for binary indicators...");
        let mut score = 0;
        let mut details = Vec::new();

        // Check for GitHub Actions or CI that builds binaries
        let github_dir = repo_dir.join(".github");
        if github_dir.is_dir() {
            for entry in
                fs::read_dir(github_dir).unwrap_or_else(|_| fs::read_dir("/dev/null").unwrap())
            {
                if let Ok(entry) = entry {
                    let path = entry.path();
                    if path.is_file()
                        && path
                            .extension()
                            .map_or(false, |ext| ext == "yml" || ext == "yaml")
                    {
                        if let Ok(content) = fs::read_to_string(&path) {
                            if content.contains("go build") || content.contains("goreleaser") {
                                score += 2;
                                details.push("CI: Binary build detected".to_string());
                                break;
                            }
                        }
                    }
                }
            }
        }

        // Check for release files
        if repo_dir.join("goreleaser.yml").exists() || repo_dir.join(".goreleaser.yml").exists() {
            score += 2;
            details.push("Release: GoReleaser config".to_string());
        }

        // Check for Dockerfile
        if repo_dir.join("Dockerfile").exists() {
            if let Ok(content) = fs::read_to_string(repo_dir.join("Dockerfile")) {
                if content.contains("ENTRYPOINT") || content.contains("CMD") {
                    score += 1;
                    details.push("Container: Executable Docker image".to_string());
                }
            }
        }

        (score, details)
    }

    fn analyze(&self, repo_dir: &Path) -> Result<Analysis> {
        // Check if it's a Go project
        if !repo_dir.join("go.mod").exists() {
            let go_files = self.find_go_files(repo_dir)?;
            if go_files.is_empty() {
                return Err(anyhow!("Not a Go project (no go.mod or .go files found)"));
            }
        }

        let (main_packages, mut all_details) = self.check_main_packages(repo_dir)?;
        let (directory_score, mut dir_details) = self.check_directory_structure(repo_dir);
        let (readme_score, mut readme_details) = self.check_readme(repo_dir);
        let (executable_score, mut exec_details) = self.check_executable_indicators(repo_dir);
        let (go_mod_score, mut mod_details) = self.check_go_mod(repo_dir);
        let (binary_score, mut bin_details) = self.check_binary_indicators(repo_dir);

        all_details.append(&mut dir_details);
        all_details.append(&mut readme_details);
        all_details.append(&mut exec_details);
        all_details.append(&mut mod_details);
        all_details.append(&mut bin_details);

        let total_score = (main_packages as i32) * 5
            + directory_score
            + readme_score
            + executable_score
            + go_mod_score
            + binary_score;

        let (project_type, confidence) = if main_packages > 0 {
            (ProjectType::Cli, "HIGH")
        } else if total_score >= 6 {
            (ProjectType::Cli, "HIGH")
        } else if total_score >= 3 {
            (ProjectType::Cli, "MEDIUM")
        } else if total_score <= -3 {
            (ProjectType::Library, "HIGH")
        } else if total_score <= 0 {
            (ProjectType::Library, "MEDIUM")
        } else {
            (ProjectType::Unclear, "LOW")
        };

        Ok(Analysis {
            main_packages,
            directory_score,
            readme_score,
            executable_score,
            go_mod_score,
            binary_score,
            total_score,
            project_type,
            confidence,
            details: all_details,
        })
    }

    fn output_results(&self, analysis: &Analysis, url: &str) {
        match self.output_format {
            OutputFormat::Json => {
                let json = json!({
                    "url": url,
                    "type": analysis.project_type.as_str(),
                    "confidence": analysis.confidence,
                    "score": analysis.total_score,
                    "analysis": {
                        "main_packages": analysis.main_packages,
                        "directory_score": analysis.directory_score,
                        "readme_score": analysis.readme_score,
                        "executable_score": analysis.executable_score,
                        "go_mod_score": analysis.go_mod_score,
                        "binary_score": analysis.binary_score
                    },
                    "details": analysis.details
                });
                println!("{}", json);
            }
            OutputFormat::Simple => {
                println!("{}", analysis.project_type.as_str());
            }
            OutputFormat::Human => {
                if !self.quiet {
                    eprintln!("\n=== ANALYSIS RESULTS ===");
                    eprintln!(
                        "Main packages: {} (×5 = {} points)",
                        analysis.main_packages,
                        analysis.main_packages * 5
                    );
                    eprintln!("Directory score: {} points", analysis.directory_score);
                    eprintln!("README score: {} points", analysis.readme_score);
                    eprintln!("Executable score: {} points", analysis.executable_score);
                    eprintln!("Go.mod score: {} points", analysis.go_mod_score);
                    eprintln!("Binary score: {} points", analysis.binary_score);
                    eprintln!("Total score: {} points", analysis.total_score);

                    if self.verbose && !analysis.details.is_empty() {
                        eprintln!("\nDetection details:");
                        for detail in &analysis.details {
                            eprintln!("  • {}", detail);
                        }
                    }

                    eprintln!();
                    let (emoji, color) = match analysis.project_type {
                        ProjectType::Cli => ("🔧", "\x1b[32m"),
                        ProjectType::Library => ("📚", "\x1b[34m"),
                        ProjectType::Unclear => ("❓", "\x1b[33m"),
                    };
                    eprintln!(
                        "{} RESULT: {}{}\x1b[0m (Confidence: {})",
                        emoji,
                        color,
                        analysis.project_type.as_str().to_uppercase(),
                        analysis.confidence
                    );
                    eprintln!("URL: {}", url);
                }
            }
        }
    }

    async fn detect(&self, url: &str) -> Result<Analysis> {
        let (url_type, processed_url) = self.detect_url_type(url)?;

        let temp_dir = TempDir::new()?;
        let repo_dir = temp_dir.path().join("repo");
        fs::create_dir_all(&repo_dir)?;

        match url_type {
            "git" => self.clone_git(&processed_url, &repo_dir)?,
            "archive" => self.download_archive(&processed_url, &repo_dir).await?,
            _ => return Err(anyhow!("Unknown URL type")),
        }

        self.analyze(&repo_dir)
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let matches = ClapCommand::new("go-detector")
        .version("0.2.0")
        .about("Detects if a Go project is a CLI tool or library with improved accuracy")
        .arg(
            Arg::new("url")
                .required(true)
                .help("Git repository URL or archive URL"),
        )
        .arg(
            Arg::new("quiet")
                .short('q')
                .long("quiet")
                .action(clap::ArgAction::SetTrue)
                .help("Suppress progress messages"),
        )
        .arg(
            Arg::new("json")
                .short('j')
                .long("json")
                .action(clap::ArgAction::SetTrue)
                .help("Output results in JSON format"),
        )
        .arg(
            Arg::new("simple")
                .short('s')
                .long("simple")
                .action(clap::ArgAction::SetTrue)
                .help("Output only the project type"),
        )
        .arg(
            Arg::new("verbose")
                .short('v')
                .long("verbose")
                .action(clap::ArgAction::SetTrue)
                .help("Show detailed analysis information"),
        )
        .get_matches();

    let url = matches.get_one::<String>("url").unwrap();
    let quiet = matches.get_flag("quiet");
    let verbose = matches.get_flag("verbose");

    let output_format = if matches.get_flag("json") {
        OutputFormat::Json
    } else if matches.get_flag("simple") {
        OutputFormat::Simple
    } else {
        OutputFormat::Human
    };

    let detector = match Detector::new(quiet, verbose, output_format) {
        Ok(d) => d,
        Err(e) => {
            eprintln!("Failed to initialize detector: {}", e);
            std::process::exit(4);
        }
    };

    match detector.detect(url).await {
        Ok(analysis) => {
            detector.output_results(&analysis, url);
            std::process::exit(analysis.project_type.exit_code());
        }
        Err(e) => {
            detector.log_error(&format!("{}", e));
            std::process::exit(3);
        }
    }
}
