use clap::{Arg, Command};
use indicatif::{MultiProgress, ProgressBar, ProgressStyle};
use reqwest::Client;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::fs;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{Mutex, Semaphore};
use tokio::time::sleep;
use url::Url;
use urlencoding::encode;

#[derive(Debug, Serialize, Deserialize, Clone)]
struct InputEntry {
    download: String,
    source: String,
    version: String,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
struct OutputEntry {
    description: String,
    download: String,
    homepage: String,
    license: Vec<String>,
    stars: String,
    source: String,
    version: String,
}

#[derive(Debug, Clone)]
struct Config {
    api_url: String,
    user_agent: String,
    threads: usize,
    verbose: bool,
    quiet: bool,
    max_retries: u32,
    base_delay_ms: u64,
}

#[derive(Debug)]
struct EnrichmentResult {
    input: InputEntry,
    output: Result<OutputEntry, String>,
}

const DEFAULT_DESCRIPTION: &str = "No Description Provided";

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let rt = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;

    rt.block_on(async_main())
}

async fn async_main() -> Result<(), Box<dyn std::error::Error>> {
    let matches = Command::new("go-enricher")
        .version("0.0.1")
        .author("Azathothas | QaidVoid")
        .about("Enrich Go Index Data")
        .arg(
            Arg::new("input")
                .short('i')
                .long("input")
                .value_name("FILE")
                .help("Input JSON file containing Go modules")
                .conflicts_with("source"),
        )
        .arg(
            Arg::new("output")
                .short('o')
                .long("output")
                .value_name("FILE")
                .help("Output file path (stdout if not specified)"),
        )
        .arg(
            Arg::new("api-url")
                .long("api-url")
                .value_name("URL")
                .default_value("https://api.deps.dev/v3/projects/")
                .help("Base API URL for deps.dev"),
        )
        .arg(
            Arg::new("user-agent")
                .long("user-agent")
                .value_name("STRING")
                // https://github.com/pkgforge/devscripts/blob/main/Misc/User-Agents/ua_safari_macos_latest.txt
                .default_value("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15")
                .help("User agent string for HTTP requests"),
        )
        .arg(
            Arg::new("threads")
                .short('t')
                .long("threads")
                .value_name("NUM")
                .default_value("10")
                .help("Number of concurrent HTTP requests"),
        )
        .arg(
            Arg::new("verbose")
                .short('v')
                .long("verbose")
                .action(clap::ArgAction::SetTrue)
                .help("Enable verbose output"),
        )
        .arg(
            Arg::new("quiet")
                .short('q')
                .long("quiet")
                .action(clap::ArgAction::SetTrue)
                .help("Suppress progress output")
                .conflicts_with("verbose"),
        )
        .arg(
            Arg::new("source")
                .value_name("SOURCE")
                .help("Single Go module source (e.g., github.com/user/repo)")
                .conflicts_with("input"),
        )
        .arg(
            Arg::new("max-retries")
                .long("max-retries")
                .value_name("NUM")
                .default_value("3")
                .help("Maximum number of retry attempts for failed API requests"),
        )
        .arg(
            Arg::new("base-delay")
                .long("base-delay-ms")
                .value_name("MS")
                .default_value("1000")
                .help("Base delay in milliseconds for exponential backoff"),
        )
        .get_matches();

    let config = Config {
        api_url: matches.get_one::<String>("api-url").unwrap().clone(),
        user_agent: matches.get_one::<String>("user-agent").unwrap().clone(),
        threads: matches.get_one::<String>("threads").unwrap().parse()?,
        verbose: matches.get_flag("verbose"),
        quiet: matches.get_flag("quiet"),
        max_retries: matches.get_one::<String>("max-retries").unwrap().parse()?,
        base_delay_ms: matches.get_one::<String>("base-delay").unwrap().parse()?,
    };

    if config.verbose {
        println!(
            "🚀 Starting go-enricher with {} concurrent requests",
            config.threads
        );
        println!("📡 API URL: {}", config.api_url);
        println!("🤖 User Agent: {}", config.user_agent);
        println!(
            "🔄 Max retries: {}, Base delay: {}ms",
            config.max_retries, config.base_delay_ms
        );
    }

    let client = Client::builder()
        .user_agent(&config.user_agent)
        .timeout(Duration::from_secs(30))
        .build()?;

    // Determine input mode
    if let Some(input_file) = matches.get_one::<String>("input") {
        // File input mode
        if config.verbose {
            println!("📁 Reading input file: {}", input_file);
        }

        let input_data = fs::read_to_string(input_file)
            .map_err(|e| format!("Failed to read input file '{}': {}", input_file, e))?;

        let entries: Vec<InputEntry> = serde_json::from_str(&input_data)
            .map_err(|e| format!("Failed to parse input JSON: {}", e))?;

        if entries.is_empty() {
            return Err("Input file contains no entries".into());
        }

        if config.verbose {
            println!("📊 Found {} entries to process", entries.len());
        }

        let results = process_entries(entries, &client, &config).await?;

        // Validate JSON output before writing
        let output_data = serde_json::to_string_pretty(&results)
            .map_err(|e| format!("Failed to serialize output to valid JSON: {}", e))?;

        // Additional JSON validation
        serde_json::from_str::<Vec<OutputEntry>>(&output_data)
            .map_err(|e| format!("Output JSON validation failed: {}", e))?;

        if let Some(output_file) = matches.get_one::<String>("output") {
            // Ensure output directory exists
            if let Some(parent) = Path::new(output_file).parent() {
                fs::create_dir_all(parent)
                    .map_err(|e| format!("Failed to create output directory: {}", e))?;
            }

            // Check for accidental overwrites
            if Path::new(output_file).exists() {
                return Err(format!(
                    "Output file '{}' already exists. Remove it first or choose a different path.",
                    output_file
                )
                .into());
            }

            fs::write(output_file, &output_data)
                .map_err(|e| format!("Failed to write output file '{}': {}", output_file, e))?;

            if !config.quiet {
                println!("✅ Results written to: {}", output_file);
            }
        } else {
            println!("{}", output_data);
        }
    } else if let Some(source) = matches.get_one::<String>("source") {
        // Single source mode
        if config.verbose {
            println!("🎯 Processing single source: {}", source);
        }

        let entry = InputEntry {
            download: String::new(), // Not available in single mode
            source: source.clone(),
            version: String::new(), // Not available in single mode
        };

        let result = enrich_single_entry(&entry, &client, &config).await;

        match result {
            Ok(enriched) => {
                let json_output = serde_json::to_string_pretty(&enriched)
                    .map_err(|e| format!("Failed to serialize output to valid JSON: {}", e))?;

                // Validate JSON before output
                serde_json::from_str::<OutputEntry>(&json_output)
                    .map_err(|e| format!("Output JSON validation failed: {}", e))?;

                println!("{}", json_output);
            }
            Err(e) => {
                return Err(format!("Failed to enrich source '{}': {}", source, e).into());
            }
        }
    } else {
        return Err("Either --input file or source argument must be provided".into());
    }

    if config.verbose {
        println!("🎉 Processing completed successfully!");
    }

    Ok(())
}

async fn process_entries(
    entries: Vec<InputEntry>,
    client: &Client,
    config: &Config,
) -> Result<Vec<OutputEntry>, Box<dyn std::error::Error>> {
    let semaphore = Arc::new(Semaphore::new(config.threads));
    let results = Arc::new(Mutex::new(Vec::new()));

    let multi_progress = if !config.quiet {
        Some(MultiProgress::new())
    } else {
        None
    };

    let main_pb = if let Some(ref mp) = multi_progress {
        let pb = mp.add(ProgressBar::new(entries.len() as u64));
        pb.set_style(
            ProgressStyle::default_bar()
                .template("[{elapsed_precise}] {bar:40.cyan/blue} {pos:>7}/{len:7} {msg}")
                .unwrap()
                .progress_chars("##-"),
        );
        pb.set_message("Enriching modules...");
        Some(pb)
    } else {
        None
    };

    let mut handles = Vec::new();

    for entry in entries.into_iter() {
        let semaphore = semaphore.clone();
        let client = client.clone();
        let config = config.clone();
        let results = results.clone();
        let main_pb = main_pb.clone();

        let handle = tokio::spawn(async move {
            let _permit = semaphore.acquire().await.unwrap();

            if config.verbose {
                println!("🔄 Processing: {}", entry.source);
            }

            let result = enrich_single_entry(&entry, &client, &config).await;

            let enrichment_result = EnrichmentResult {
                input: entry.clone(),
                output: result,
            };

            if let Some(ref pb) = main_pb {
                pb.inc(1);
                match &enrichment_result.output {
                    Ok(_) => pb.set_message(format!("✅ Completed: {}", entry.source)),
                    Err(e) => pb.set_message(format!("❌ Failed: {} ({})", entry.source, e)),
                }
            }

            results.lock().await.push(enrichment_result);
        });

        handles.push(handle);
    }

    // Wait for all tasks to complete
    for handle in handles {
        handle.await?;
    }

    if let Some(pb) = main_pb {
        pb.finish_with_message("All modules processed");
    }

    let results_guard = results.lock().await;
    let mut output_entries = Vec::new();
    let mut failed_count = 0;

    for result in results_guard.iter() {
        match &result.output {
            Ok(output) => output_entries.push(output.clone()),
            Err(e) => {
                failed_count += 1;
                if config.verbose {
                    eprintln!("❌ Failed to enrich {}: {}", result.input.source, e);
                }
            }
        }
    }

    if !config.quiet {
        println!(
            "📊 Summary: {} successful, {} failed",
            output_entries.len(),
            failed_count
        );
    }

    if output_entries.is_empty() {
        return Err("No entries were successfully enriched".into());
    }

    Ok(output_entries)
}

async fn enrich_single_entry(
    entry: &InputEntry,
    client: &Client,
    config: &Config,
) -> Result<OutputEntry, String> {
    let processed_source = process_source(&entry.source)?;
    let encoded_source = encode(&processed_source).to_string();
    let api_url = format!("{}{}", config.api_url, encoded_source);

    if config.verbose {
        println!("🌐 API Request: {} -> {}", entry.source, api_url);
    }

    // Retry logic with exponential backoff
    let mut last_error = String::new();
    for attempt in 0..=config.max_retries {
        if attempt > 0 {
            let delay = config.base_delay_ms * (2_u64.pow(attempt - 1));
            if config.verbose {
                println!(
                    "⏳ Retrying {} in {}ms (attempt {}/{})",
                    entry.source, delay, attempt, config.max_retries
                );
            }
            sleep(Duration::from_millis(delay)).await;
        }

        match make_api_request(&api_url, client).await {
            Ok(api_data) => {
                let enriched_data = extract_fields(&api_data)?;

                return Ok(OutputEntry {
                    description: sanitize_and_validate_description(&enriched_data.description),
                    download: sanitize_field(&entry.download),
                    homepage: sanitize_field(&enriched_data.homepage),
                    license: enriched_data
                        .license
                        .into_iter()
                        .map(|l| sanitize_field(&l))
                        .collect(),
                    stars: enriched_data
                        .stars
                        .map(|s| sanitize_field(&s.to_string()))
                        .unwrap_or_default(),
                    source: sanitize_field(&entry.source),
                    version: sanitize_field(&entry.version),
                });
            }
            Err(e) => {
                // Don't retry 404 errors
                if e == "RESOURCE_NOT_FOUND" {
                    return Err(
                        "Resource not found (404) - module does not exist in API".to_string()
                    );
                }

                last_error = e;
                if config.verbose && attempt < config.max_retries {
                    println!(
                        "🔥 Attempt {} failed for {}: {}",
                        attempt + 1,
                        entry.source,
                        last_error
                    );
                }
            }
        }
    }

    Err(format!(
        "All {} attempts failed. Last error: {}",
        config.max_retries + 1,
        last_error
    ))
}

async fn make_api_request(api_url: &str, client: &Client) -> Result<Value, String> {
    let response = client.get(api_url).send().await.map_err(|e| {
        if e.is_timeout() {
            "Request timed out".to_string()
        } else if e.is_connect() {
            "Connection failed".to_string()
        } else {
            format!("HTTP request failed: {}", e)
        }
    })?;

    let status = response.status();

    // Handle different HTTP status codes
    match status.as_u16() {
        200..=299 => {
            // Success
            response
                .json()
                .await
                .map_err(|e| format!("Failed to parse API response as JSON: {}", e))
        }
        429 => {
            // Rate limited
            Err("API rate limit exceeded".to_string())
        }
        500..=599 => {
            // Server error - retryable
            Err(format!("Server error: {}", status))
        }
        404 => {
            // Not found - not retryable, return specific error
            Err("RESOURCE_NOT_FOUND".to_string())
        }
        _ => {
            // Other client errors
            Err(format!("API returned status: {}", status))
        }
    }
}

fn process_source(source: &str) -> Result<String, String> {
    let source = source.trim();

    // Handle different URL formats
    let normalized = if source.starts_with("http://") || source.starts_with("https://") {
        // Parse as full URL
        let url = Url::parse(source).map_err(|e| format!("Invalid URL format: {}", e))?;

        let host = url.host_str().ok_or("URL missing hostname")?;

        let path = url.path().trim_start_matches('/').trim_end_matches('/');

        if path.is_empty() {
            host.to_string()
        } else {
            format!("{}/{}", host, path)
        }
    } else {
        // Assume it's already in the correct format
        source.trim_end_matches('/').to_string()
    };

    if normalized.is_empty() {
        return Err("Empty source after processing".into());
    }

    Ok(normalized)
}

#[derive(Debug)]
struct ExtractedFields {
    description: String,
    homepage: String,
    license: Vec<String>,
    stars: Option<u64>,
}

fn extract_fields(data: &Value) -> Result<ExtractedFields, String> {
    let mut description = None;
    let mut homepage = None;
    let mut license = Vec::new();
    let mut stars = None;

    find_fields_recursive(
        data,
        &mut description,
        &mut homepage,
        &mut license,
        &mut stars,
    );

    let description = description.unwrap_or_else(|| DEFAULT_DESCRIPTION.to_string());

    Ok(ExtractedFields {
        description,
        homepage: homepage.unwrap_or_default(),
        license: if license.is_empty() { vec![] } else { license },
        stars,
    })
}

fn find_fields_recursive(
    value: &Value,
    description: &mut Option<String>,
    homepage: &mut Option<String>,
    license: &mut Vec<String>,
    stars: &mut Option<u64>,
) {
    match value {
        Value::Object(map) => {
            for (key, val) in map {
                let key_lower = key.to_lowercase();

                // Check for description
                if description.is_none() && (key_lower == "description") {
                    if let Some(desc) = val.as_str() {
                        let trimmed = desc.trim();
                        if !trimmed.is_empty() {
                            *description = Some(trimmed.to_string());
                        }
                    }
                }

                // Check for homepage
                if homepage.is_none() && (key_lower == "homepage") {
                    if let Some(home) = val.as_str() {
                        let trimmed = home.trim();
                        if !trimmed.is_empty() {
                            *homepage = Some(trimmed.to_string());
                        }
                    }
                }

                // Check for license
                if key_lower == "license" {
                    match val {
                        Value::String(lic) => {
                            let trimmed = lic.trim().to_string();
                            if !trimmed.is_empty() && !license.contains(&trimmed) {
                                license.push(trimmed);
                            }
                        }
                        Value::Array(arr) => {
                            for item in arr {
                                if let Some(lic) = item.as_str() {
                                    let trimmed = lic.trim().to_string();
                                    if !trimmed.is_empty() && !license.contains(&trimmed) {
                                        license.push(trimmed);
                                    }
                                }
                            }
                        }
                        _ => {}
                    }
                }

                // Check for stars
                if stars.is_none()
                    && (key_lower == "stars"
                        || key_lower == "starscount"
                        || key_lower == "stargazers_count")
                {
                    if let Some(star_count) = val.as_u64() {
                        *stars = Some(star_count);
                    }
                }

                // Recurse into nested objects and arrays
                find_fields_recursive(val, description, homepage, license, stars);
            }
        }
        Value::Array(arr) => {
            for item in arr {
                find_fields_recursive(item, description, homepage, license, stars);
            }
        }
        _ => {}
    }
}

/// Sanitize field by removing dangerous characters and trimming whitespace
fn sanitize_field(input: &str) -> String {
    input
        .trim()
        .chars()
        .filter(|&c| {
            // Allow alphanumeric, basic punctuation, spaces, but exclude dangerous shell chars
            match c {
                // Dangerous characters for shell injection
                //'`' | '$' | '\\' | '|' | '&' | ';' | '>' | '<' | '(' | ')' | '{' | '}' | '[' | ']' | '*' | '?' | '!' => false,
                '`' | '$' | '\\' => false,
                // Control characters
                c if c.is_control() => false,
                // Allow everything else (letters, numbers, basic punctuation, spaces)
                _ => true,
            }
        })
        .collect::<String>()
        .trim()
        .to_string()
}

/// Sanitize and validate description field with additional checks
fn sanitize_and_validate_description(input: &str) -> String {
    let sanitized = sanitize_field(input);

    // If empty after sanitization, use default
    if sanitized.trim().is_empty() {
        return DEFAULT_DESCRIPTION.to_string();
    }

    let mut chars: Vec<char> = sanitized.chars().collect();

    // Ensure first character is alphanumeric
    if let Some(first_char) = chars.first_mut() {
        if !first_char.is_alphanumeric() {
            // Find first alphanumeric character or prepend default text
            let first_alnum_pos = chars.iter().position(|c| c.is_alphanumeric());
            if let Some(pos) = first_alnum_pos {
                chars.drain(0..pos);
            } else {
                // No alphanumeric characters found, use default
                return DEFAULT_DESCRIPTION.to_string();
            }
        }
    }

    // Ensure last character is alphanumeric
    if let Some(last_char) = chars.last_mut() {
        if !last_char.is_alphanumeric() {
            // Find last alphanumeric character
            let last_alnum_pos = chars.iter().rposition(|c| c.is_alphanumeric());
            if let Some(pos) = last_alnum_pos {
                chars.truncate(pos + 1);
            } else {
                // No alphanumeric characters found, use default
                return DEFAULT_DESCRIPTION.to_string();
            }
        }
    }

    let result: String = chars.into_iter().collect();

    // Final check - if empty or too short, use default
    if result.trim().len() < 2 {
        DEFAULT_DESCRIPTION.to_string()
    } else {
        // Capitalize the first letter
        capitalize_first_letter(&result)
    }
}

/// Capitalize the first letter of a string
fn capitalize_first_letter(s: &str) -> String {
    let mut chars = s.chars();
    match chars.next() {
        None => String::new(),
        Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
    }
}
