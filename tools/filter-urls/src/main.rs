use clap::{Arg, Command};
use reqwest::Client;
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::fs;
use std::io::{self, BufRead, BufReader};
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::Semaphore;
use tokio::time::sleep;
use url::Url;

#[derive(Debug, Clone, Serialize, Deserialize)]
struct UrlResult {
    input: String,
    method: String,
    status: Option<u16>,
    time: String,
    result: String,
}

#[derive(Debug, Clone)]
struct Config {
    concurrency: usize,
    in_place: bool,
    json: bool,
    pretty: bool,
    method: String,
    output: Option<String>,
    quiet: bool,
    retry: bool,
    force_retry: bool,
    status_codes: HashSet<u16>,
    verbose: bool,
    input_file: Option<String>,
    user_agent: String,
}

impl Default for Config {
    fn default() -> Self {
        let mut status_codes = HashSet::new();
        status_codes.insert(404);

        Self {
            concurrency: 10,
            in_place: false,
            json: false,
            pretty: false,
            method: "HEAD".to_string(),
            output: None,
            quiet: false,
            retry: false,
            force_retry: false,
            status_codes,
            verbose: false,
            input_file: None,
            user_agent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15".to_string(),
        }
    }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let matches = Command::new("filter-urls")
        .version("0.0.1")
        .about("Remove URLs from files based on HTTP status codes")
        .arg(
            Arg::new("concurrency")
                .short('c')
                .long("concurrency")
                .value_name("NUM")
                .help("Number of concurrent requests")
                .default_value("10"),
        )
        .arg(
            Arg::new("in-place")
                .short('i')
                .long("in-place")
                .help("Edit file in place")
                .action(clap::ArgAction::SetTrue),
        )
        .arg(
            Arg::new("json")
                .short('j')
                .long("json")
                .help("Output JSON format")
                .action(clap::ArgAction::SetTrue),
        )
        .arg(
            Arg::new("pretty")
                .short('p')
                .long("pretty")
                .help("Pretty table output")
                .action(clap::ArgAction::SetTrue),
        )
        .arg(
            Arg::new("method")
                .short('m')
                .long("method")
                .value_name("METHOD")
                .help("HTTP method to use")
                .default_value("HEAD"),
        )
        .arg(
            Arg::new("output")
                .short('o')
                .long("output")
                .value_name("FILE")
                .help("Output file path"),
        )
        .arg(
            Arg::new("quiet")
                .short('q')
                .long("quiet")
                .help("Quiet mode - no stdout output")
                .action(clap::ArgAction::SetTrue),
        )
        .arg(
            Arg::new("retry")
                .short('r')
                .long("retry")
                .help("Retry on connection errors")
                .action(clap::ArgAction::SetTrue),
        )
        .arg(
            Arg::new("force-retry")
                .short('f')
                .long("force-retry")
                .help("Force retry with exponential backoff (max 3 attempts)")
                .action(clap::ArgAction::SetTrue),
        )
        .arg(
            Arg::new("status-code")
                .short('s')
                .long("status-code")
                .value_name("CODES")
                .help("Status codes to filter (comma-separated)")
                .default_value("404"),
        )
        .arg(
            Arg::new("user-agent")
                .short('u')
                .long("user-agent")
                .value_name("USER_AGENT")
                .help("User agent string to use for requests")
                //https://github.com/pkgforge/devscripts/blob/main/Misc/User-Agents/ua_safari_macos_latest.txt
                .default_value(
                    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
                ),
        )
        .arg(
            Arg::new("verbose")
                .short('v')
                .long("verbose")
                .help("Verbose output")
                .action(clap::ArgAction::SetTrue),
        )
        .arg(
            Arg::new("input")
                .help("Input file (or stdin if not provided)")
                .index(1),
        )
        .get_matches();

    let mut config = Config::default();

    // Parse arguments
    config.concurrency = matches
        .get_one::<String>("concurrency")
        .unwrap()
        .parse()
        .unwrap_or(10);
    config.in_place = matches.get_flag("in-place");
    config.json = matches.get_flag("json");
    config.pretty = matches.get_flag("pretty");
    config.method = matches.get_one::<String>("method").unwrap().to_uppercase();
    config.output = matches.get_one::<String>("output").map(|s| s.to_string());
    config.quiet = matches.get_flag("quiet");
    config.retry = matches.get_flag("retry");
    config.force_retry = matches.get_flag("force-retry");
    config.verbose = matches.get_flag("verbose");
    config.input_file = matches.get_one::<String>("input").map(|s| s.to_string());
    config.user_agent = matches.get_one::<String>("user-agent").unwrap().to_string();

    // Parse status codes
    let status_codes_str = matches.get_one::<String>("status-code").unwrap();
    config.status_codes = status_codes_str
        .split(',')
        .filter_map(|s| s.trim().parse::<u16>().ok())
        .collect();

    if config.status_codes.is_empty() {
        config.status_codes.insert(404);
    }

    // Read input
    let lines = read_input(&config)?;

    // Process URLs
    let results = process_urls(lines, &config).await?;

    // Handle output
    handle_output(results, &config).await?;

    Ok(())
}

fn read_input(config: &Config) -> Result<Vec<String>, Box<dyn std::error::Error>> {
    let lines = if let Some(input_file) = &config.input_file {
        let content = fs::read_to_string(input_file)?;
        content.lines().map(|s| s.to_string()).collect()
    } else {
        let stdin = io::stdin();
        let reader = BufReader::new(stdin.lock());
        reader.lines().collect::<Result<Vec<_>, _>>()?
    };

    Ok(lines)
}

async fn process_urls(
    lines: Vec<String>,
    config: &Config,
) -> Result<Vec<UrlResult>, Box<dyn std::error::Error>> {
    let client = Client::builder()
        .timeout(Duration::from_secs(30))
        .user_agent(&config.user_agent)
        .build()?;

    let semaphore = Arc::new(Semaphore::new(config.concurrency));
    let mut tasks = Vec::new();

    for line in lines {
        let trimmed = line.trim().to_string();
        if trimmed.is_empty() {
            continue;
        }

        // Validate URL
        if !is_valid_url(&trimmed) {
            if config.verbose {
                eprintln!("Skipping invalid URL: {}", trimmed);
            }
            continue;
        }

        let client = client.clone();
        let config = config.clone();
        let semaphore = semaphore.clone();

        let task = tokio::spawn(async move {
            let _permit = semaphore.acquire().await.unwrap();
            check_url(trimmed, client, &config).await
        });

        tasks.push(task);
    }

    let mut results = Vec::new();
    for task in tasks {
        match task.await {
            Ok(result) => results.push(result),
            Err(e) => eprintln!("Task error: {}", e),
        }
    }

    Ok(results)
}

fn is_valid_url(url_str: &str) -> bool {
    match Url::parse(url_str) {
        Ok(url) => {
            matches!(url.scheme(), "http" | "https" | "ftp" | "ftps")
        }
        Err(_) => false,
    }
}

async fn check_url(url: String, client: Client, config: &Config) -> UrlResult {
    let start_time = Instant::now();
    let mut attempts = 0;
    let max_attempts = if config.force_retry { 3 } else { 1 };

    loop {
        attempts += 1;

        let request_result = match config.method.as_str() {
            "GET" => client.get(&url).send().await,
            "POST" => client.post(&url).send().await,
            "PUT" => client.put(&url).send().await,
            "DELETE" => client.delete(&url).send().await,
            _ => client.head(&url).send().await, // Default to HEAD
        };

        let _elapsed = start_time.elapsed();
        let time_iso = chrono::Utc::now().to_rfc3339();

        match request_result {
            Ok(response) => {
                let status = response.status().as_u16();
                let result = if config.status_codes.contains(&status) {
                    "filtered"
                } else {
                    "unchanged"
                };

                return UrlResult {
                    input: url,
                    method: config.method.clone(),
                    status: Some(status),
                    time: time_iso,
                    result: result.to_string(),
                };
            }
            Err(e) => {
                if attempts >= max_attempts || (!config.retry && !config.force_retry) {
                    if config.verbose {
                        eprintln!("Failed to check {}: {}", url, e);
                    }

                    return UrlResult {
                        input: url,
                        method: config.method.clone(),
                        status: None,
                        time: time_iso,
                        result: "unchanged".to_string(),
                    };
                }

                if config.force_retry && attempts < max_attempts {
                    let delay = Duration::from_millis(100 * (2_u64.pow(attempts - 1)));
                    sleep(delay).await;
                }
            }
        }
    }
}

async fn handle_output(
    results: Vec<UrlResult>,
    config: &Config,
) -> Result<(), Box<dyn std::error::Error>> {
    let filtered_results: Vec<_> = results.iter().filter(|r| r.result == "unchanged").collect();

    if config.in_place {
        if let Some(input_file) = &config.input_file {
            let output_lines: Vec<String> =
                filtered_results.iter().map(|r| r.input.clone()).collect();

            fs::write(input_file, output_lines.join("\n"))?;
        }
    }

    if let Some(output_path) = &config.output {
        if let Some(parent) = Path::new(output_path).parent() {
            fs::create_dir_all(parent)?;
        }

        let output_lines: Vec<String> = filtered_results.iter().map(|r| r.input.clone()).collect();

        fs::write(output_path, output_lines.join("\n"))?;
    }

    if !config.quiet {
        if config.json {
            let json_output = serde_json::to_string_pretty(&results)?;
            println!("{}", json_output);
        } else if config.pretty {
            print_pretty_table(&results);
        } else if config.verbose || (!config.in_place && config.output.is_none()) {
            for result in &filtered_results {
                println!("{}", result.input);
            }

            if config.verbose {
                for result in &results {
                    if result.result == "filtered" {
                        if let Some(status) = result.status {
                            eprintln!("Filtered: {} (status: {})", result.input, status);
                        } else {
                            eprintln!("Filtered: {} (connection failed)", result.input);
                        }
                    }
                }
            }
        } else if !config.in_place && config.output.is_none() {
            for result in &filtered_results {
                println!("{}", result.input);
            }
        }
    }

    Ok(())
}

fn print_pretty_table(results: &[UrlResult]) {
    println!(
        "{:<50} {:<8} {:<8} {:<25} {:<10}",
        "URL", "METHOD", "STATUS", "TIME", "RESULT"
    );
    println!("{}", "-".repeat(101));

    for result in results {
        let status_str = result
            .status
            .map(|s| s.to_string())
            .unwrap_or_else(|| "ERROR".to_string());

        let time_short = result
            .time
            .split('T')
            .nth(1)
            .unwrap_or(&result.time)
            .split('.')
            .next()
            .unwrap_or(&result.time);

        println!(
            "{:<50} {:<8} {:<8} {:<25} {:<10}",
            truncate_string(&result.input, 48),
            result.method,
            status_str,
            time_short,
            result.result
        );
    }
}

fn truncate_string(s: &str, max_len: usize) -> String {
    if s.len() <= max_len {
        s.to_string()
    } else {
        format!("{}...", &s[..max_len - 3])
    }
}
