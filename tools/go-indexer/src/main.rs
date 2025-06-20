//TODO: rewrite this properly, currently it is AI Garbage that does the bare minimum

use anyhow::{anyhow, Context, Result};
use chrono::{NaiveDate, Utc};
use clap::{Arg, Command};
use indexmap::IndexMap;
use indicatif::{MultiProgress, ProgressBar, ProgressStyle};
use reqwest::{Client, StatusCode};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;
use std::fs::{create_dir_all, File};
use std::io::{BufRead, BufReader, BufWriter, Write};
use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::fs::{remove_file, OpenOptions};
use tokio::io::AsyncWriteExt;
use tokio::time::sleep;
use tokio_util::sync::CancellationToken;

#[derive(Debug, Clone)]
struct Config {
    start_date: NaiveDate,
    end_date: NaiveDate,
    output_file: String,
    max_concurrent_days: usize,
    max_retries: usize,
    batch_size: usize,
    request_timeout: Duration,
    dry_run: bool,
    resume_mode: bool,
    verbose: bool,
    process_output: bool,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            start_date: NaiveDate::from_ymd_opt(2019, 1, 1).unwrap(),
            end_date: Utc::now().date_naive(),
            output_file: "go_index.jsonl".to_string(),
            max_concurrent_days: 30,
            max_retries: 3,
            batch_size: 2000,
            request_timeout: Duration::from_secs(30),
            dry_run: false,
            resume_mode: false,
            verbose: false,
            process_output: true,
        }
    }
}

#[allow(dead_code)]
#[derive(Debug, Deserialize)]
struct IndexEntry {
    #[serde(rename = "Path")]
    path: Option<String>,
    #[serde(rename = "Version")]
    version: Option<String>,
    #[serde(rename = "Timestamp")]
    timestamp: Option<String>,
}

#[derive(Serialize)]
struct GroupedResult {
    source: String,
    versions: Vec<String>,
}

#[derive(Clone)]
struct Statistics {
    total_days: usize,
    completed_days: Arc<AtomicUsize>,
    total_records: Arc<AtomicUsize>,
    total_errors: Arc<AtomicUsize>,
    start_time: Instant,
}

impl Statistics {
    fn new(total_days: usize) -> Self {
        Self {
            total_days,
            completed_days: Arc::new(AtomicUsize::new(0)),
            total_records: Arc::new(AtomicUsize::new(0)),
            total_errors: Arc::new(AtomicUsize::new(0)),
            start_time: Instant::now(),
        }
    }

    fn increment_completed(&self) {
        self.completed_days.fetch_add(1, Ordering::Relaxed);
    }

    fn add_records(&self, count: usize) {
        self.total_records.fetch_add(count, Ordering::Relaxed);
    }

    fn add_errors(&self, count: usize) {
        self.total_errors.fetch_add(count, Ordering::Relaxed);
    }

    fn print_final(&self) {
        let elapsed = self.start_time.elapsed();
        let completed = self.completed_days.load(Ordering::Relaxed);
        let records = self.total_records.load(Ordering::Relaxed);
        let errors = self.total_errors.load(Ordering::Relaxed);

        println!("\n🎉 Processing Complete!");
        println!("┌─────────────────────────────────────┐");
        println!("│ Final Statistics                    │");
        println!("├─────────────────────────────────────┤");
        println!(
            "│ Duration: {:>24} │",
            format!("{:.2}s", elapsed.as_secs_f64())
        );
        println!(
            "│ Days processed: {:>18} │",
            format!("{}/{}", completed, self.total_days)
        );
        println!("│ Total records: {:>19} │", records);
        println!("│ Errors: {:>26} │", errors);
        println!(
            "│ Rate: {:>28} │",
            format!("{:.0} records/sec", records as f64 / elapsed.as_secs_f64())
        );
        println!("└─────────────────────────────────────┘");
    }
}

async fn create_http_client(timeout: Duration) -> Client {
    Client::builder()
        .timeout(timeout)
        // https://github.com/pkgforge/devscripts/blob/main/Misc/User-Agents/ua_safari_macos_latest.txt
        .user_agent("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15")
        .gzip(true)
        .build()
        .expect("Failed to create HTTP client")
}

async fn fetch_with_retry(
    client: &Client,
    url: &str,
    max_retries: usize,
    progress: &ProgressBar,
) -> Result<String> {
    let mut attempt = 1;
    let mut delay = Duration::from_secs(2);

    loop {
        progress.set_message(format!("Attempt {}/{}", attempt, max_retries));

        match client.get(url).send().await {
            Ok(response) => match response.status() {
                StatusCode::OK => {
                    let text = response.text().await?;
                    return Ok(text);
                }
                StatusCode::TOO_MANY_REQUESTS => {
                    if attempt >= max_retries {
                        return Err(anyhow!("Rate limited after {} attempts", max_retries));
                    }
                    progress.set_message("Rate limited, waiting...");
                    sleep(Duration::from_secs(5)).await;
                }
                status if status.is_server_error() => {
                    if attempt >= max_retries {
                        return Err(anyhow!(
                            "Server error {} after {} attempts",
                            status,
                            max_retries
                        ));
                    }
                    progress.set_message(format!("Server error {}, retrying...", status));
                    sleep(delay).await;
                }
                status => {
                    return Err(anyhow!("HTTP error: {}", status));
                }
            },
            Err(e) => {
                if attempt >= max_retries {
                    return Err(anyhow!(
                        "Network error after {} attempts: {}",
                        max_retries,
                        e
                    ));
                }
                progress.set_message(format!("Network error, retrying... ({})", e));
                sleep(delay).await;
            }
        }

        attempt += 1;
        delay = std::cmp::min(delay * 2, Duration::from_secs(60)); // Exponential backoff with cap
    }
}

async fn process_day(
    client: &Client,
    date: NaiveDate,
    config: &Config,
    temp_dir: &Path,
    stats: &Statistics,
    progress: &ProgressBar,
    _token: CancellationToken,
) -> Result<usize> {
    let day_output = temp_dir.join(format!("day_{}.jsonl", date.format("%Y_%m_%d")));

    // Check if already processed in resume mode
    if config.resume_mode && day_output.exists() {
        if let Ok(metadata) = tokio::fs::metadata(&day_output).await {
            if metadata.len() > 0 {
                progress.set_message("Already processed (skipping)");
                progress.finish_with_message("✓ Skipped (already processed)");
                stats.increment_completed();
                return Ok(0);
            }
        }
    }

    let mut output_file = tokio::io::BufWriter::with_capacity(
        64 * 1024,
        OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .open(&day_output)
            .await?,
    );

    let since = format!("{}T00:00:00Z", date.format("%Y-%m-%d"));
    let next_day = date.succ_opt().unwrap_or(date);
    let until = format!("{}T00:00:00Z", next_day.format("%Y-%m-%d"));

    let mut batch_num = 0;
    let mut current_since = since.clone();
    let mut prev_timestamp = String::new();
    let mut empty_batches = 0;
    let mut total_records = 0;

    progress.set_message("Starting...");

    loop {
        //let url = format!(
        //    "https://api.rv.pkgforge.dev/https://index.golang.org/index?include=all&limit={}&since={}&until={}",
        //    config.batch_size, current_since, until
        //);
        let url = format!(
            "https://index.golang.org/index?include=all&limit={}&since={}&until={}",
            config.batch_size, current_since, until
        );

        progress.set_message(format!("Batch {} ({} records)", batch_num, total_records));

        match fetch_with_retry(client, &url, config.max_retries, progress).await {
            Ok(response_text) => {
                if response_text.trim().is_empty() {
                    empty_batches += 1;
                    if empty_batches >= 3 {
                        break;
                    }
                    continue;
                }

                empty_batches = 0;
                let mut valid_lines = 0;
                let mut new_timestamp = String::new();

                let mut buffer = String::with_capacity(response_text.len() + 1000);
                for line in response_text.lines() {
                    if line.trim().is_empty() {
                        continue;
                    }
                    match serde_json::from_str::<Value>(line) {
                        Ok(json) => {
                            buffer.push_str(line);
                            buffer.push('\n');
                            valid_lines += 1;

                            // Extract timestamp for next iteration
                            if let Some(timestamp) = json.get("Timestamp").and_then(|t| t.as_str())
                            {
                                new_timestamp = timestamp.to_string();
                            }
                        }
                        Err(_) => {
                            stats.add_errors(1);
                            continue;
                        }
                    }
                }

                if !buffer.is_empty() {
                    output_file.write_all(buffer.as_bytes()).await?;
                }
                if valid_lines == 0 {
                    break;
                }

                total_records += valid_lines;
                stats.add_records(valid_lines);

                // Check stopping conditions
                if new_timestamp.is_empty() || new_timestamp == prev_timestamp {
                    break;
                }

                let new_date = new_timestamp.split('T').next().unwrap_or("");
                if new_date != date.format("%Y-%m-%d").to_string() {
                    break;
                }

                if valid_lines < config.batch_size {
                    break;
                }

                prev_timestamp = current_since.clone();
                current_since = new_timestamp;
                batch_num += 1;

                if batch_num > 1000 {
                    progress.set_message("Safety limit reached");
                    break;
                }

                // Brief pause
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
            Err(e) => {
                stats.add_errors(1);
                progress.finish_with_message(format!("✗ Failed: {}", e));
                return Err(e);
            }
        }
    }

    output_file.flush().await?;
    stats.increment_completed();
    progress.finish_with_message(format!("✓ {} records", total_records));
    Ok(total_records)
}

async fn process_days_parallel(
    config: &Config,
    dates: Vec<NaiveDate>,
    temp_dir: &Path,
    stats: &Statistics,
) -> Result<()> {
    let client = create_http_client(config.request_timeout).await;
    let multi_progress = MultiProgress::new();

    let style = ProgressStyle::default_bar()
        .template("{prefix:.bold.dim} {spinner:.green} [{elapsed_precise}] {wide_msg}")
        .unwrap();

    let main_pb = multi_progress.add(ProgressBar::new(dates.len() as u64));
    main_pb.set_style(
        ProgressStyle::default_bar()
            .template("🚀 {msg} [{bar:40.cyan/blue}] {pos}/{len} days ({percent}%) ETA: {eta}")
            .unwrap(),
    );
    main_pb.set_message("Processing days");

    let semaphore = Arc::new(tokio::sync::Semaphore::new(config.max_concurrent_days));
    let token = CancellationToken::new();
    let mut handles = Vec::new();

    for date in dates {
        let permit = semaphore.clone().acquire_owned().await?;
        let client = client.clone();
        let config = config.clone();
        let temp_dir = temp_dir.to_path_buf();
        let stats = stats.clone();
        let token = token.clone();

        let pb = multi_progress.add(ProgressBar::new_spinner());
        pb.set_style(style.clone());
        pb.set_prefix(date.format("%Y-%m-%d").to_string());
        pb.enable_steady_tick(Duration::from_millis(100));
        let main_pb = main_pb.clone();

        let handle = tokio::spawn(async move {
            let _permit = permit;
            let result = process_day(&client, date, &config, &temp_dir, &stats, &pb, token).await;
            main_pb.inc(1);
            result
        });

        handles.push(handle);
    }

    // Wait for all tasks to complete
    let mut total_errors = 0;
    for handle in handles {
        match handle.await? {
            Ok(_) => {}
            Err(_) => total_errors += 1,
        }
    }

    main_pb.finish_with_message("All days completed");
    multi_progress.clear()?;

    if total_errors > 0 {
        println!("⚠️  {} days failed to process", total_errors);
    }

    Ok(())
}

async fn combine_daily_files(
    dates: &[NaiveDate],
    temp_dir: &Path,
    output_file: &str,
    resume_mode: bool,
) -> Result<usize> {
    println!("📦 Combining daily files into final output...");

    if !resume_mode && Path::new(output_file).exists() {
        remove_file(output_file).await?;
    }

    if let Some(parent) = Path::new(output_file).parent() {
        create_dir_all(parent)?;
    }

    let final_output = OpenOptions::new()
        .create(true)
        .append(true)
        .open(output_file)
        .await?;
    let mut buffered_output = tokio::io::BufWriter::with_capacity(256 * 1024, final_output); // Smaller buffer

    let mut total_lines = 0;
    let pb = ProgressBar::new(dates.len() as u64);
    pb.set_style(
        ProgressStyle::default_bar()
            .template("📋 Combining [{bar:40.green/blue}] {pos}/{len} files {msg}")
            .unwrap(),
    );

    for date in dates {
        let path = temp_dir.join(format!("day_{}.jsonl", date.format("%Y_%m_%d")));

        if path.exists() {
            // Use smaller buffer and simpler approach
            let contents = tokio::fs::read_to_string(&path).await?;
            if !contents.is_empty() {
                buffered_output.write_all(contents.as_bytes()).await?;
                let line_count = contents.lines().count();
                total_lines += line_count;
            }
        }
        pb.set_message(format!("({} lines)", total_lines));
        pb.inc(1);
    }

    buffered_output.flush().await?;
    pb.finish_with_message(format!("✓ {} total lines", total_lines));
    Ok(total_lines)
}

// Post-processing functionality
fn extract_field(obj: &Value, variants: &[&str]) -> Option<String> {
    if let Value::Object(map) = obj {
        for variant in variants {
            if let Some(Value::String(val)) = map.get(*variant) {
                return Some(val.clone());
            }
        }
    }
    None
}

fn remove_duplicates_preserve_order(versions: Vec<String>) -> Vec<String> {
    let mut seen = IndexMap::new();
    for version in versions {
        seen.insert(version, ());
    }
    seen.into_keys().collect()
}

async fn process_output_file(input_file: &str) -> Result<()> {
    println!("🔄 Post-processing output file...");

    let processed_file = format!("{}.processed.json", input_file.trim_end_matches(".jsonl"));

    let file = File::open(input_file)?;
    let reader = BufReader::with_capacity(256 * 1024, file);

    let mut grouped: HashMap<String, Vec<String>> = HashMap::with_capacity(10000);
    let source_fields = ["Path", "path"];
    let version_fields = ["Version", "version"];

    let pb = ProgressBar::new_spinner();
    pb.set_style(
        ProgressStyle::default_spinner()
            .template("🔍 Processing {msg} {spinner:.green}")
            .unwrap(),
    );
    pb.enable_steady_tick(Duration::from_millis(100));

    let mut line_count = 0;
    let mut processed_count = 0;
    let mut error_count = 0;

    for line_result in reader.lines() {
        line_count += 1;

        if line_count % 10000 == 0 {
            pb.set_message(format!(
                "{} lines | {} valid | {} errors",
                line_count, processed_count, error_count
            ));
        }

        let line = line_result?;
        if line.trim().is_empty() {
            continue;
        }

        let obj: Value = match serde_json::from_str(&line) {
            Ok(obj) => obj,
            Err(_) => {
                error_count += 1;
                continue;
            }
        };

        let source = match extract_field(&obj, &source_fields) {
            Some(s) => s,
            None => {
                error_count += 1;
                continue;
            }
        };

        let version = match extract_field(&obj, &version_fields) {
            Some(v) => v,
            None => {
                error_count += 1;
                continue;
            }
        };

        grouped.entry(source).or_insert_with(Vec::new).push(version);
        processed_count += 1;
    }

    pb.finish_with_message(format!("✓ Processed {} lines", line_count));

    println!("📊 Grouping {} unique sources...", grouped.len());

    let mut results: Vec<GroupedResult> = Vec::with_capacity(grouped.len());
    for (source, versions) in grouped {
        results.push(GroupedResult {
            source,
            versions: remove_duplicates_preserve_order(versions),
        });
    }

    results.sort_unstable_by(|a, b| a.source.cmp(&b.source));

    println!("💾 Writing processed output...");

    if let Some(parent) = Path::new(&processed_file).parent() {
        create_dir_all(parent)?;
    }

    let file = File::create(&processed_file)?;
    let mut writer = BufWriter::with_capacity(256 * 1024, file);
    let json_output = serde_json::to_string_pretty(&results)?;
    writer.write_all(json_output.as_bytes())?;
    writer.flush()?;

    let total_versions: usize = results.iter().map(|r| r.versions.len()).sum();

    println!("✅ Post-processing complete!");
    println!("📄 Processed file: {}", processed_file);
    println!("📊 Unique sources: {}", results.len());
    println!("🏷️  Total versions: {}", total_versions);

    Ok(())
}

fn generate_dates(start: NaiveDate, end: NaiveDate) -> Vec<NaiveDate> {
    let mut dates = Vec::new();
    let mut current = start;

    while current < end {
        dates.push(current);
        current = current.succ_opt().unwrap_or(current);
        if current == start {
            break; // Prevent infinite loop
        }
    }

    dates
}

fn build_cli() -> Command {
    let today: &'static str = Box::leak(Utc::now().format("%Y-%m-%d").to_string().into_boxed_str());
    Command::new("go-indexer")
        .version("0.0.1")
        .author("Azathothas | QaidVoid")
        .about("Go index fetcher from index.golang.org")
        .arg(
            Arg::new("start-date")
                .long("start-date")
                .required(true)
                .value_name("DATE")
                .help("Start date in YYYY-MM-DD format")
                .default_value("2019-01-01"),
        )
        .arg(
            Arg::new("end-date")
                .long("end-date")
                .value_name("DATE")
                .help("End date in YYYY-MM-DD format")
                .default_value(today),
        )
        .arg(
            Arg::new("output")
                .long("output")
                .short('o')
                .value_name("FILE")
                .help("Output file path")
                .default_value("go_index.jsonl"),
        )
        .arg(
            Arg::new("concurrent")
                .long("concurrent")
                .value_name("N")
                .help("Max concurrent days to process")
                .default_value("30"),
        )
        .arg(
            Arg::new("retries")
                .long("retries")
                .value_name("N")
                .help("Max retries per request")
                .default_value("3"),
        )
        .arg(
            Arg::new("batch-size")
                .long("batch-size")
                .value_name("N")
                .help("Records per batch")
                .default_value("2000"),
        )
        .arg(
            Arg::new("timeout")
                .long("timeout")
                .value_name("SECONDS")
                .help("Request timeout in seconds")
                .default_value("30"),
        )
        .arg(
            Arg::new("dry-run")
                .long("dry-run")
                .help("Show what would be done without executing")
                .action(clap::ArgAction::SetTrue),
        )
        .arg(
            Arg::new("resume")
                .long("resume")
                .help("Resume from existing partial data")
                .action(clap::ArgAction::SetTrue),
        )
        .arg(
            Arg::new("verbose")
                .long("verbose")
                .short('v')
                .help("Enable verbose output")
                .action(clap::ArgAction::SetTrue),
        )
        .arg(
            Arg::new("no-process")
                .long("no-process")
                .help("Skip post-processing step")
                .action(clap::ArgAction::SetTrue),
        )
}

#[tokio::main]
async fn main() -> Result<()> {
    let matches = build_cli().get_matches();

    let mut config = Config::default();

    // Parse dates
    let start_date_str = matches.get_one::<String>("start-date").unwrap_or_else(|| {
        eprintln!("❌ Missing required --start-date argument");
        std::process::exit(1);
    });
    let end_date_str = matches.get_one::<String>("end-date").unwrap();

    config.start_date = NaiveDate::parse_from_str(start_date_str, "%Y-%m-%d")
        .with_context(|| format!("Invalid start date: {}", start_date_str))?;
    config.end_date = NaiveDate::parse_from_str(end_date_str, "%Y-%m-%d")
        .with_context(|| format!("Invalid end date: {}", end_date_str))?;

    if config.start_date >= config.end_date {
        return Err(anyhow!("Start date must be before end date"));
    }
    let start_date_fmt = config.start_date.format("%Y-%m-%d").to_string();
    let end_date_fmt = config.end_date.format("%Y-%m-%d").to_string();

    // Parse other options
    config.output_file = matches.get_one::<String>("output").unwrap().clone();
    config.max_concurrent_days = matches.get_one::<String>("concurrent").unwrap().parse()?;
    config.max_retries = matches.get_one::<String>("retries").unwrap().parse()?;
    config.batch_size = matches.get_one::<String>("batch-size").unwrap().parse()?;
    config.request_timeout =
        Duration::from_secs(matches.get_one::<String>("timeout").unwrap().parse()?);
    config.dry_run = matches.get_flag("dry-run");
    config.resume_mode = matches.get_flag("resume");
    config.verbose = matches.get_flag("verbose");
    config.process_output = !matches.get_flag("no-process");

    // Print configuration

    println!("Go Modules Index Fetcher");
    println!("┌────────────────────────────────────────────────────────────┐");
    println!("│ Configuration                                              │");
    println!("├────────────────────────────────────────────────────────────┤");
    println!("│ {:<28} : {:>27} │", "Start date", start_date_fmt);
    println!("│ {:<28} : {:>27} │", "End date", end_date_fmt);
    println!("│ {:<28} : {:>27} │", "Output file", config.output_file);
    println!(
        "│ {:<28} : {:>27} │",
        "Max concurrent", config.max_concurrent_days
    );
    println!("│ {:<28} : {:>27} │", "Max retries", config.max_retries);
    println!("│ {:<28} : {:>27} │", "Batch size", config.batch_size);
    println!(
        "│ {:<28} : {:>27} │",
        "Timeout",
        format!("{}s", config.request_timeout.as_secs())
    );
    println!("│ {:<28} : {:>27} │", "Dry run", config.dry_run);
    println!("│ {:<28} : {:>27} │", "Resume mode", config.resume_mode);
    println!(
        "│ {:<28} : {:>27} │",
        "Process output", config.process_output
    );
    println!("└────────────────────────────────────────────────────────────┘");

    let dates = generate_dates(config.start_date, config.end_date);
    println!("📅 Generated {} dates to process", dates.len());

    if config.dry_run {
        println!(
            "🔍 DRY RUN: Would process dates from {} to {}",
            config.start_date, config.end_date
        );
        println!(
            "📁 DRY RUN: Would create output file: {}",
            config.output_file
        );
        return Ok(());
    }

    // Create temp directory
    let temp_dir_handle = tempfile::tempdir()?;
    let temp_dir = temp_dir_handle.path();
    println!("📂 Temp directory: {}", temp_dir.display());

    let stats = Statistics::new(dates.len());

    // Process all days
    process_days_parallel(&config, dates.clone(), &temp_dir, &stats).await?;

    // Combine daily files
    let total_lines =
        combine_daily_files(&dates, &temp_dir, &config.output_file, config.resume_mode).await?;

    // Post-process if requested
    if config.process_output {
        process_output_file(&config.output_file).await?;
    }

    // Print final statistics
    stats.print_final();

    if let Ok(metadata) = std::fs::metadata(&config.output_file) {
        println!(
            "📊 Final output: {} ({:.2} MB, {} lines)",
            config.output_file,
            metadata.len() as f64 / 1_048_576.0,
            total_lines
        );
    }

    // Cleanup temp directory
    if let Err(e) = std::fs::remove_dir_all(&temp_dir) {
        eprintln!("⚠️  Failed to cleanup temp directory: {}", e);
    }

    Ok(())
}
