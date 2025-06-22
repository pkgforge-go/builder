use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use anyhow::{anyhow, Result};
use clap::{Arg, Command as ClapCommand};
use indicatif::{ProgressBar, ProgressStyle};
use regex::Regex;
use reqwest;
use serde_json::json;
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
    total_score: i32,
    project_type: ProjectType,
    confidence: &'static str,
}

struct Detector {
    quiet: bool,
    verbose: bool,
    output_format: OutputFormat,
}

impl Detector {
    fn new(quiet: bool, verbose: bool, output_format: OutputFormat) -> Self {
        Self {
            quiet,
            verbose,
            output_format,
        }
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
        
        if url.ends_with(".tar.gz") || url.ends_with(".tgz") || url.ends_with(".zip") 
            || url.contains("/archive/") || url.contains("/tarball/") {
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
            if !normalized.ends_with(".git") {
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

        let client = reqwest::Client::new();
        let response = client.get(url).send().await?;
        let bytes = response.bytes().await?;

        if let Some(pb) = &pb {
            pb.set_message("Extracting...");
        }

        let archive_path = extract_dir.join("archive");
        fs::write(&archive_path, &bytes)?;

        // Try tar.gz first, then zip
        let extract_success = if self.try_extract_tar(&archive_path, extract_dir).is_ok() {
            true
        } else if self.try_extract_zip(&archive_path, extract_dir).is_ok() {
            true
        } else {
            false
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

    fn try_extract_tar(&self, archive_path: &Path, extract_dir: &Path) -> Result<()> {
        let output = Command::new("tar")
            .args(&["-xzf", archive_path.to_str().unwrap(), "--strip-components=1"])
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

    fn try_extract_zip(&self, archive_path: &Path, extract_dir: &Path) -> Result<()> {
        let output = Command::new("unzip")
            .args(&["-q", "-o", archive_path.to_str().unwrap(), "-d", extract_dir.to_str().unwrap()])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()?;

        if output.success() {
            // Handle single directory extraction
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
        } else {
            Err(anyhow!("unzip extraction failed"))
        }
    }

    fn move_directory_contents(&self, source: &Path, dest: &Path) -> Result<()> {
        for entry in fs::read_dir(source)? {
            let entry = entry?;
            let dest_path = dest.join(entry.file_name());
            if entry.file_type()?.is_dir() {
                fs::rename(entry.path(), dest_path)?;
            } else {
                fs::copy(entry.path(), dest_path)?;
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

    fn check_main_packages(&self, repo_dir: &Path) -> Result<usize> {
        self.log_verbose("Checking for main packages...");
        
        let go_files = self.find_go_files(repo_dir)?;
        let mut main_count = 0;

        for file in go_files {
            if self.is_example_file(&file) {
                continue;
            }

            if let Ok(content) = fs::read_to_string(&file) {
                if Regex::new(r"^\s*package\s+main\s*$")?.is_match(&content) {
                    self.log_verbose(&format!("Found main package: {:?}", file.strip_prefix(repo_dir).unwrap_or(&file)));
                    main_count += 1;
                }
            }
        }

        Ok(main_count)
    }

    fn find_go_files(&self, dir: &Path) -> Result<Vec<PathBuf>> {
        let mut go_files = Vec::new();
        self.find_go_files_recursive(dir, &mut go_files)?;
        Ok(go_files)
    }

    fn find_go_files_recursive(&self, dir: &Path, files: &mut Vec<PathBuf>) -> Result<()> {
        for entry in fs::read_dir(dir)? {
            let entry = entry?;
            let path = entry.path();
            
            if path.is_dir() && !self.is_ignored_dir(&path) {
                self.find_go_files_recursive(&path, files)?;
            } else if path.extension().map_or(false, |ext| ext == "go") {
                files.push(path);
            }
        }
        Ok(())
    }

    fn is_ignored_dir(&self, path: &Path) -> bool {
        if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
            matches!(name, "vendor" | "node_modules" | ".git" | ".github")
        } else {
            false
        }
    }

    fn is_example_file(&self, path: &Path) -> bool {
        let path_str = path.to_string_lossy();
        path_str.contains("/example") || path_str.contains("/demo") || 
        path_str.contains("/test") || path_str.ends_with("_test.go")
    }

    fn check_directory_structure(&self, repo_dir: &Path) -> i32 {
        self.log_verbose("Analyzing directory structure...");
        let mut score = 0;

        if repo_dir.join("cmd").is_dir() {
            self.log_verbose("Found 'cmd/' directory (+3 points)");
            score += 3;
        }

        if repo_dir.join("main.go").is_file() {
            self.log_verbose("Found 'main.go' in root (+2 points)");
            score += 2;
        }

        if (repo_dir.join("pkg").is_dir() || repo_dir.join("lib").is_dir() || repo_dir.join("internal").is_dir())
            && !repo_dir.join("main.go").exists() && !repo_dir.join("cmd").exists() {
            self.log_verbose("Library structure without main entry points (-1 point)");
            score -= 1;
        }

        score
    }

    fn check_readme(&self, repo_dir: &Path) -> i32 {
        self.log_verbose("Analyzing README...");
        let mut score = 0;

        let readme_patterns = ["readme", "README", "Readme", "readme.md", "README.md", "readme.txt", "README.txt"];
        
        for pattern in &readme_patterns {
            let readme_path = repo_dir.join(pattern);
            if readme_path.is_file() {
                if let Ok(content) = fs::read_to_string(&readme_path) {
                    let content_lower = content.to_lowercase();
                    
                    if content_lower.contains("go install") && content_lower.contains("@latest") {
                        self.log_verbose("Found binary installation instructions (+2 points)");
                        score += 2;
                    }
                    
                    if content_lower.contains("cli tool") || content_lower.contains("command line") {
                        self.log_verbose("Found CLI tool keywords (+1 point)");
                        score += 1;
                    }
                    
                    if Regex::new(r"\$ [a-zA-Z0-9_-]+\s").unwrap().is_match(&content) {
                        self.log_verbose("Found command-line usage examples (+1 point)");
                        score += 1;
                    }
                }
                break;
            }
        }

        score
    }

    fn check_executable_indicators(&self, repo_dir: &Path) -> i32 {
        self.log_verbose("Checking for executable indicators...");
        let mut score = 0;

        let go_files = self.find_go_files(repo_dir).unwrap_or_default();
        let cli_patterns = [
            "flag.",
            "os.Args",
            "cobra.",
            "spf13/cobra",
            "urfave/cli",
            "func main()",
        ];

        for file in go_files {
            if self.is_example_file(&file) {
                continue;
            }

            if let Ok(content) = fs::read_to_string(&file) {
                for pattern in &cli_patterns {
                    if content.contains(pattern) {
                        self.log_verbose(&format!("Found CLI indicator: {} (+1 point)", pattern));
                        score += 1;
                        break;
                    }
                }
            }
        }

        score
    }

    fn analyze(&self, repo_dir: &Path) -> Result<Analysis> {
        // Check if it's a Go project
        if !repo_dir.join("go.mod").exists() {
            let go_files = self.find_go_files(repo_dir)?;
            if go_files.is_empty() {
                return Err(anyhow!("Not a Go project (no go.mod or .go files found)"));
            }
        }

        let main_packages = self.check_main_packages(repo_dir)?;
        let directory_score = self.check_directory_structure(repo_dir);
        let readme_score = self.check_readme(repo_dir);
        let executable_score = self.check_executable_indicators(repo_dir);

        let total_score = (main_packages as i32) * 5 + directory_score + readme_score + executable_score;

        let (project_type, confidence) = if main_packages > 0 {
            (ProjectType::Cli, "HIGH")
        } else if total_score >= 4 {
            (ProjectType::Cli, "MEDIUM")
        } else if total_score <= -2 {
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
            total_score,
            project_type,
            confidence,
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
                        "executable_score": analysis.executable_score
                    }
                });
                println!("{}", json);
            }
            OutputFormat::Simple => {
                println!("{}", analysis.project_type.as_str());
            }
            OutputFormat::Human => {
                if !self.quiet {
                    eprintln!("\n=== ANALYSIS RESULTS ===");
                    eprintln!("Main packages: {} (×5 = {} points)", analysis.main_packages, analysis.main_packages * 5);
                    eprintln!("Directory score: {} points", analysis.directory_score);
                    eprintln!("README score: {} points", analysis.readme_score);
                    eprintln!("Executable score: {} points", analysis.executable_score);
                    eprintln!("Total score: {} points", analysis.total_score);
                    eprintln!();

                    let (emoji, color) = match analysis.project_type {
                        ProjectType::Cli => ("🔧", "\x1b[32m"),
                        ProjectType::Library => ("📚", "\x1b[34m"),
                        ProjectType::Unclear => ("❓", "\x1b[33m"),
                    };

                    eprintln!("{} RESULT: {}{}\x1b[0m (Confidence: {})", 
                             emoji, color, analysis.project_type.as_str().to_uppercase(), analysis.confidence);
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
        .version("0.1.0")
        .about("Detects if a Go project is a CLI tool or library")
        .arg(Arg::new("url").required(true).help("Git or archive URL"))
        .arg(Arg::new("quiet").short('q').long("quiet").action(clap::ArgAction::SetTrue))
        .arg(Arg::new("json").short('j').long("json").action(clap::ArgAction::SetTrue))
        .arg(Arg::new("simple").short('s').long("simple").action(clap::ArgAction::SetTrue))
        .arg(Arg::new("verbose").short('v').long("verbose").action(clap::ArgAction::SetTrue))
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

    let detector = Detector::new(quiet, verbose, output_format);
    
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