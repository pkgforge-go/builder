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
}

#[derive(Debug)]
struct EnrichmentResult {
    input: InputEntry,
    output: Result<OutputEntry, String>,
}

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
                .default_value("go-enricher/1.0.0")
                .help("User agent string for HTTP requests"),
        )
        .arg(
            Arg::new("threads")
                .short('t')
                .long("threads")
                .value_name("NUM")
                .default_value("10")
                .help("Number of concurrent threads"),
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
        .get_matches();

    let config = Config {
        api_url: matches.get_one::<String>("api-url").unwrap().clone(),
        user_agent: matches.get_one::<String>("user-agent").unwrap().clone(),
        threads: matches.get_one::<String>("threads").unwrap().parse()?,
        verbose: matches.get_flag("verbose"),
        quiet: matches.get_flag("quiet"),
    };

    if config.verbose {
        println!("🚀 Starting go-enricher with {} threads", config.threads);
        println!("📡 API URL: {}", config.api_url);
        println!("🤖 User Agent: {}", config.user_agent);
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
        
        let output_data = serde_json::to_string_pretty(&results)
            .map_err(|e| format!("Failed to serialize output: {}", e))?;

        if let Some(output_file) = matches.get_one::<String>("output") {
            // Ensure output directory exists
            if let Some(parent) = Path::new(output_file).parent() {
                fs::create_dir_all(parent)
                    .map_err(|e| format!("Failed to create output directory: {}", e))?;
            }

            // Check for accidental overwrites
            if Path::new(output_file).exists() {
                return Err(format!("Output file '{}' already exists. Remove it first or choose a different path.", output_file).into());
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
            version: String::new(),  // Not available in single mode
        };

        let result = enrich_single_entry(&entry, &client, &config).await;
        
        match result {
            Ok(enriched) => {
                let json_output = serde_json::to_string_pretty(&enriched)
                    .map_err(|e| format!("Failed to serialize output: {}", e))?;
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
        println!("📊 Summary: {} successful, {} failed", output_entries.len(), failed_count);
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

    let response = client
        .get(&api_url)
        .send()
        .await
        .map_err(|e| format!("HTTP request failed: {}", e))?;

    if !response.status().is_success() {
        return Err(format!("API returned status: {}", response.status()));
    }

    let api_data: Value = response
        .json()
        .await
        .map_err(|e| format!("Failed to parse API response: {}", e))?;

    let enriched_data = extract_fields(&api_data)?;

    Ok(OutputEntry {
        description: enriched_data.description,
        download: entry.download.clone(),
        homepage: enriched_data.homepage,
        license: enriched_data.license,
        stars: enriched_data.stars.map(|s| s.to_string()).unwrap_or_default(),
        source: entry.source.clone(),
        version: entry.version.clone(),
    })
}

fn process_source(source: &str) -> Result<String, String> {
    let source = source.trim();
    
    // Handle different URL formats
    let normalized = if source.starts_with("http://") || source.starts_with("https://") {
        // Parse as full URL
        let url = Url::parse(source)
            .map_err(|e| format!("Invalid URL format: {}", e))?;
        
        let host = url.host_str()
            .ok_or("URL missing hostname")?;
        
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

    find_fields_recursive(data, &mut description, &mut homepage, &mut license, &mut stars);

    let description = description.ok_or("Required field 'description' not found in API response")?;

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
                        *description = Some(desc.to_string());
                    }
                }
                
                // Check for homepage
                if homepage.is_none() && (key_lower == "homepage") {
                    if let Some(home) = val.as_str() {
                        *homepage = Some(home.to_string());
                    }
                }
                
                // Check for license
                if key_lower == "license" {
                    match val {
                        Value::String(lic) => {
                            if !license.contains(lic) {
                                license.push(lic.clone());
                            }
                        }
                        Value::Array(arr) => {
                            for item in arr {
                                if let Some(lic) = item.as_str() {
                                    if !license.contains(&lic.to_string()) {
                                        license.push(lic.to_string());
                                    }
                                }
                            }
                        }
                        _ => {}
                    }
                }
                
                // Check for stars
                if stars.is_none() && (key_lower == "stars" || key_lower == "starscount" || key_lower == "starscount") {
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