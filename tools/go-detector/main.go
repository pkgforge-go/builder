package main

import (
	"archive/tar"
	"archive/zip"
	"bufio"
	"compress/gzip"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"io"
	"net/http"
	"os"
	"path/filepath"
	//"regexp"
	"runtime"
	//"strconv"
	"strings"
	"sync"
	"time"
)

// Exit codes
const (
	ExitCLI     = 0  // Project is CLI
	ExitLibrary = 1  // Project is Library  
	ExitUnclear = 2  // Unable to determine clearly
	ExitError   = 3  // Error occurred
)

//TEMP Dirs
var tempDirs []string
var tempFiles []string
var tempDirsMutex sync.Mutex
var tempMutex sync.Mutex

func registerTempDir(dir string) {
    tempMutex.Lock()
    defer tempMutex.Unlock()
    tempDirs = append(tempDirs, dir)
}

func registerTempFile(file string) {
    tempMutex.Lock()
    defer tempMutex.Unlock()
    tempFiles = append(tempFiles, file)
}

func cleanupTempResources() {
    tempMutex.Lock()
    defer tempMutex.Unlock()
    
    for _, file := range tempFiles {
        os.Remove(file)
    }
    
    for _, dir := range tempDirs {
        os.RemoveAll(dir)
    }
}

//Project
type ProjectType int

const (
	Unclear ProjectType = iota
	CLI
	Library
)

func (pt ProjectType) String() string {
	switch pt {
	case CLI:
		return "cli"
	case Library:
		return "library"
	default:
		return "unclear"
	}
}

type Evidence struct {
	Type        string  `json:"type"`
	Description string  `json:"description"`
	File        string  `json:"file,omitempty"`
	Weight      float64 `json:"weight"`
	Confidence  float64 `json:"confidence"`
}

type ProjectAnalysis struct {
	Type                ProjectType `json:"type"`
	TypeString          string      `json:"type_string"`
	Confidence          float64     `json:"confidence"`
	ExitCode            int         `json:"exit_code"`
	
	// Core indicators
	HasMainFunction     bool     `json:"has_main_function"`
	HasMainPackage      bool     `json:"has_main_package"`
	HasLibraryPackages  bool     `json:"has_library_packages"`
	HasExportedSymbols  bool     `json:"has_exported_symbols"`
	
	// File analysis
	MainFiles           []string `json:"main_files"`
	LibraryPackages     []string `json:"library_packages"`
	TotalGoFiles        int      `json:"total_go_files"`
	TestFiles           int      `json:"test_files"`
	
	// Additional indicators
	HasCmdDirectory     bool     `json:"has_cmd_directory"`
	HasInternalPackages bool     `json:"has_internal_packages"`
	HasGoMod            bool     `json:"has_go_mod"`
	ModuleName          string   `json:"module_name,omitempty"`
	
	// CLI-specific indicators
	HasFlagUsage        bool     `json:"has_flag_usage"`
	HasCobraUsage       bool     `json:"has_cobra_usage"`
	HasOSExit           bool     `json:"has_os_exit"`
	HasMainInit         bool     `json:"has_main_init"`
	HasBinaryName       bool     `json:"has_binary_name"`
	HasVersionFlag      bool     `json:"has_version_flag"`
	HasHelpText         bool     `json:"has_help_text"`
	HasStdinReading     bool     `json:"has_stdin_reading"`
	
	// Library-specific indicators
	HasDocGo            bool     `json:"has_doc_go"`
	HasExampleTests     bool     `json:"has_example_tests"`
	HasPublicAPI        bool     `json:"has_public_api"`
	HasInterfaces       bool     `json:"has_interfaces"`
	HasBenchmarkTests   bool     `json:"has_benchmark_tests"`
	HasGoGenerate       bool     `json:"has_go_generate"`
	HasConstants        bool     `json:"has_constants"`
	HasTypeDefinitions  bool     `json:"has_type_definitions"`
	
	// Advanced indicators
	MainToLibraryRatio  float64  `json:"main_to_library_ratio"`
	ExportedSymbolCount int      `json:"exported_symbol_count"`
	PackageDepth        int      `json:"package_depth"`
	HasSubcommands      bool     `json:"has_subcommands"`
	HasConfigFiles      bool     `json:"has_config_files"`
	
	// Evidence chain
	Evidence            []Evidence `json:"evidence"`
	
	// Metadata
	ProjectPath         string   `json:"project_path"`
	AnalyzedAt          string   `json:"analyzed_at"`
	RemoteSource        string   `json:"remote_source,omitempty"`
	IsRemote            bool     `json:"is_remote"`
}

type GoProxyInfo struct {
	Version string `json:"Version"`
	Time    string `json:"Time"`
}

var (
	goproxy    = flag.String("goproxy", "", "Download and analyze Go module from proxy")
	inputFile  = flag.String("input", "", "File containing list of URLs/modules to process (one per line)")
	jsonOutput = flag.Bool("json", false, "Output in JSON format")
    local      = flag.String("local", "", "Analyze local project path")
	proxyURL   = flag.String("proxy-url", "https://proxy.golang.org", "Go proxy URL")
	quiet      = flag.Bool("q", false, "Quiet mode - only exit codes")
	remote     = flag.String("remote", "", "Download and analyze remote archive (zip/tar.gz)")
	verbose    = flag.Bool("v", false, "Verbose output (ignored in JSON mode)")
	workers    = flag.Int("workers", runtime.GOMAXPROCS(0), "Number of parallel workers")
)

func main() {
	flag.Parse()
	defer cleanupTempResources()

	// Handle input file mode
    if *inputFile != "" {
    	if err := processInputFile(*inputFile); err != nil {
    		if !*quiet {
    			fmt.Fprintf(os.Stderr, "Error processing input file: %v\n", err)
    		}
    		os.Exit(ExitError)
    	}
    	return
    }

	
	// Count non-empty flags
	flagCount := 0
	var projectPath string
	var isRemote bool
	var remoteSource string
	
	if *local != "" {
		flagCount++
		projectPath = *local
	}
	if *remote != "" {
		flagCount++
		projectPath = *remote
		isRemote = true
		remoteSource = *remote
	}
	if *goproxy != "" {
		flagCount++
		projectPath = *goproxy
		isRemote = true
		remoteSource = fmt.Sprintf("%s/%s", *proxyURL, *goproxy)
	}
	
	// Check if exactly one flag is provided
	if flagCount != 1 {
		if !*quiet {
			fmt.Fprintf(os.Stderr, "Usage: %s [flags] --local <path> | --remote <url> | --goproxy <module> | --input <file>\n", os.Args[0])
			fmt.Fprintf(os.Stderr, "Flags:\n")
			flag.PrintDefaults()
			fmt.Fprintf(os.Stderr, "\nExamples:\n")
			fmt.Fprintf(os.Stderr, "  %s --local .\n", os.Args[0])
			fmt.Fprintf(os.Stderr, "  %s --remote https://github.com/user/repo/archive/main.zip\n", os.Args[0])
			fmt.Fprintf(os.Stderr, "  %s --goproxy github.com/spf13/cobra\n", os.Args[0])
			fmt.Fprintf(os.Stderr, "  %s --input urls.txt --workers 4\n", os.Args[0])
			fmt.Fprintf(os.Stderr, "\nExit codes:\n")
			fmt.Fprintf(os.Stderr, "  0: CLI application detected\n")
			fmt.Fprintf(os.Stderr, "  1: Library/module detected\n")
			fmt.Fprintf(os.Stderr, "  2: Unclear project type\n")
			fmt.Fprintf(os.Stderr, "  3: Error occurred\n")
		}
		os.Exit(ExitError)
	}

	var analysis *ProjectAnalysis
	var err error
	
	if isRemote {
		analysis, err = analyzeRemoteProject(projectPath, remoteSource)
	} else {
		analysis, err = analyzeProject(projectPath)
	}
	
	if err != nil {
		if !*quiet {
			fmt.Fprintf(os.Stderr, "Error analyzing project: %v\n", err)
		}
		os.Exit(ExitError)
	}

	// Set exit code based on type
	switch analysis.Type {
	case CLI:
		analysis.ExitCode = ExitCLI
	case Library:
		analysis.ExitCode = ExitLibrary
	default:
		analysis.ExitCode = ExitUnclear
	}

	if *jsonOutput {
		output, err := json.MarshalIndent(analysis, "", "  ")
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error marshaling JSON: %v\n", err)
			os.Exit(ExitError)
		}
		fmt.Println(string(output))
		os.Exit(0) // JSON mode always exits 0
	} else if !*quiet {
		printHumanReadable(analysis)
	}
    if isRemote {
      cleanupTempResources()
    }
	os.Exit(analysis.ExitCode)
}

type InputItem struct {
	URL        string
	IsGoProxy  bool
	LineNumber int
}

type ProcessResult struct {
	Item     InputItem
	Analysis *ProjectAnalysis
	Error    error
}

func processInputFile(filename string) error {
	file, err := os.Open(filename)
	if err != nil {
		return fmt.Errorf("failed to open input file: %v", err)
	}
	defer file.Close()

	// Parse input file
	var items []InputItem
	scanner := bufio.NewScanner(file)
	lineNum := 1
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			lineNum++
			continue
		}
		
		item := InputItem{
			URL:        line,
			LineNumber: lineNum,
		}
		
		// Determine if it's a Go proxy module (no http/https prefix)
		if !strings.HasPrefix(line, "http://") && !strings.HasPrefix(line, "https://") {
			item.IsGoProxy = true
		}
		
		items = append(items, item)
		lineNum++
	}
	
	if err := scanner.Err(); err != nil {
		return fmt.Errorf("error reading input file: %v", err)
	}
	
	if len(items) == 0 {
		if !*quiet {
			fmt.Fprintf(os.Stderr, "No valid items found in input file\n")
		}
		return nil
	}
	
	return processItemsInParallel(items)
}

func processItemsInParallel(items []InputItem) error {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	
	// Create channels
	itemChan := make(chan InputItem, len(items))
	resultChan := make(chan ProcessResult, len(items))
	
	// Start workers
	var wg sync.WaitGroup
	for i := 0; i < *workers; i++ {
		wg.Add(1)
		go worker(ctx, &wg, itemChan, resultChan)
	}
	
	// Send items to workers
	go func() {
		defer close(itemChan)
		for _, item := range items {
			select {
			case itemChan <- item:
			case <-ctx.Done():
				return
			}
		}
	}()
	
	// Collect results
	go func() {
		wg.Wait()
		close(resultChan)
	}()
	
	// Process results
	successCount := 0
	errorCount := 0
	
	for result := range resultChan {
		if result.Error != nil {
			errorCount++
			if !*quiet {
				fmt.Fprintf(os.Stderr, "Error processing line %d (%s): %v\n", 
					result.Item.LineNumber, result.Item.URL, result.Error)
			}
			continue
		}
		
		successCount++
		
		// Set exit code based on type
		switch result.Analysis.Type {
		case CLI:
			result.Analysis.ExitCode = ExitCLI
		case Library:
			result.Analysis.ExitCode = ExitLibrary
		default:
			result.Analysis.ExitCode = ExitUnclear
		}
		
		if *jsonOutput {
			output, err := json.MarshalIndent(result.Analysis, "", "  ")
			if err != nil {
				fmt.Fprintf(os.Stderr, "Error marshaling JSON for %s: %v\n", result.Item.URL, err)
				continue
			}
			fmt.Println(string(output))
		} else if !*quiet {
			fmt.Fprintf(os.Stderr, "\n=== Line %d: %s ===\n", result.Item.LineNumber, result.Item.URL)
			printHumanReadable(result.Analysis)
		}
	}
	
	if !*quiet && !*jsonOutput {
		fmt.Fprintf(os.Stderr, "\n=== SUMMARY ===\n")
		fmt.Fprintf(os.Stderr, "Processed: %d successful, %d errors\n", successCount, errorCount)
	}

	return nil
}

func worker(ctx context.Context, wg *sync.WaitGroup, itemChan <-chan InputItem, resultChan chan<- ProcessResult) {
	defer wg.Done()
	
	for {
		select {
		case item, ok := <-itemChan:
			if !ok {
				return
			}
			
			var analysis *ProjectAnalysis
			var err error
			var remoteSource string
			
			if item.IsGoProxy {
				remoteSource = fmt.Sprintf("%s/%s", *proxyURL, item.URL)
				analysis, err = analyzeRemoteProject(item.URL, remoteSource)
			} else {
				remoteSource = item.URL
				analysis, err = analyzeRemoteProject(item.URL, remoteSource)
			}
			
			resultChan <- ProcessResult{
				Item:     item,
				Analysis: analysis,
				Error:    err,
			}

            cleanupTempResources()
			
		case <-ctx.Done():
			return
		}
	}
}

func isNotFoundError(err error) bool {
	if err == nil {
		return false
	}
	errStr := err.Error()
	return strings.Contains(errStr, "status: 404") ||
		strings.Contains(errStr, "(status: 404)")
}

func analyzeRemoteProject(source, remoteSource string) (*ProjectAnalysis, error) {
	var tempDir string
	var err error
	
	maxRetries := 3
	baseDelay := time.Second
	
	for attempt := 0; attempt <= maxRetries; attempt++ {
		if *goproxy != "" {
			tempDir, err = downloadGoModule(source)
		} else {
			tempDir, err = downloadAndExtract(source)
		}
		
		if err == nil {
			if attempt > 0 {
				fmt.Fprintf(os.Stderr, "[%s] Download succeeded on attempt %d\n", source, attempt+1)
			}
			break
		}
		
		if isNotFoundError(err) {
			return nil, fmt.Errorf("[%s] resource not found (404): %v", source, err)
		}
		
		if attempt == maxRetries {
			return nil, fmt.Errorf("[%s] failed to download/extract after %d attempts: %v", source, maxRetries+1, err)
		}
		
		delay := time.Duration(1<<attempt) * baseDelay
		fmt.Fprintf(os.Stderr, "[%s] Download attempt %d failed, retrying in %v: %v\n", source, attempt+1, delay, err)
		
		time.Sleep(delay)
	}
	
	analysis, err := analyzeProject(tempDir)
	if err != nil {
		return nil, err
	}
	
	analysis.IsRemote = true
	analysis.RemoteSource = remoteSource
	
	return analysis, nil
}

func downloadGoModule(modulePath string) (string, error) {
	// Get latest version info
	versionURL := fmt.Sprintf("%s/%s/@latest", *proxyURL, modulePath)
	resp, err := http.Get(versionURL)
	if err != nil {
		return "", fmt.Errorf("failed to get module info: %v", err)
	}
	defer resp.Body.Close()
	
	if resp.StatusCode != 200 {
		return "", fmt.Errorf("module not found: %s (status: %d)", modulePath, resp.StatusCode)
	}
	
	var info GoProxyInfo
	if err := json.NewDecoder(resp.Body).Decode(&info); err != nil {
		return "", fmt.Errorf("failed to decode version info: %v", err)
	}
	
	// Download the module zip
	zipURL := fmt.Sprintf("%s/%s/@v/%s.zip", *proxyURL, modulePath, info.Version)
	zipResp, err := http.Get(zipURL)
	if err != nil {
		return "", fmt.Errorf("failed to download module: %v", err)
	}
	defer zipResp.Body.Close()
	
	if zipResp.StatusCode != 200 {
		return "", fmt.Errorf("failed to download module zip (status: %d)", zipResp.StatusCode)
	}
	
	// Create temp file for zip
	tempFile, err := os.CreateTemp("", "gomodule-*.zip")
	if err != nil {
		return "", err
	}
	registerTempFile(tempFile.Name())
	defer tempFile.Close()
	
	if _, err := io.Copy(tempFile, zipResp.Body); err != nil {
		return "", err
	}
	
	// Extract to temp directory
	tempDir, err := os.MkdirTemp("", "gomodule-extract-*")
	if err != nil {
		return "", err
	}
	registerTempDir(tempDir)
	
	if err := extractZip(tempFile.Name(), tempDir); err != nil {
		os.RemoveAll(tempDir)
		return "", err
	}
	
	// Go modules are typically nested in a version directory, find the actual content
	actualDir, err := findActualProjectDir(tempDir)
	if err != nil {
		os.RemoveAll(tempDir)
		return "", err
	}
	
	return actualDir, nil
}

func downloadAndExtract(url string) (string, error) {
	resp, err := http.Get(url)
	if err != nil {
		return "", fmt.Errorf("failed to download: %v", err)
	}
	defer resp.Body.Close()
	
	if resp.StatusCode != 200 {
		return "", fmt.Errorf("download failed with status: %d", resp.StatusCode)
	}
	
	// Create temp file
	tempFile, err := os.CreateTemp("", "download-*")
	if err != nil {
		return "", err
	}
	registerTempFile(tempFile.Name())

	defer tempFile.Close()
	
	if _, err := io.Copy(tempFile, resp.Body); err != nil {
		return "", err
	}
	
	// Create temp directory for extraction
	tempDir, err := os.MkdirTemp("", "extract-*")
	if err != nil {
		return "", err
	}
	registerTempDir(tempDir)

	// Determine file type and extract
	if strings.HasSuffix(url, ".zip") {
		err = extractZip(tempFile.Name(), tempDir)
	} else if strings.HasSuffix(url, ".tar.gz") || strings.HasSuffix(url, ".tgz") {
		err = extractTarGz(tempFile.Name(), tempDir)
	} else {
		// Try to detect by content
		if isZipFile(tempFile.Name()) {
			err = extractZip(tempFile.Name(), tempDir)
		} else {
			err = extractTarGz(tempFile.Name(), tempDir)
		}
	}
	
	if err != nil {
		os.RemoveAll(tempDir)
		return "", err
	}
	
	// Find the actual project directory (skip common wrapper directories)
	actualDir, err := findActualProjectDir(tempDir)
	if err != nil {
		os.RemoveAll(tempDir)
		return "", err
	}
	
	return actualDir, nil
}

func isZipFile(filename string) bool {
	file, err := os.Open(filename)
	if err != nil {
		return false
	}
	defer file.Close()
	
	header := make([]byte, 4)
	_, err = file.Read(header)
	if err != nil {
		return false
	}
	
	// ZIP files start with "PK"
	return header[0] == 0x50 && header[1] == 0x4B
}

func extractZip(src, dest string) error {
	reader, err := zip.OpenReader(src)
	if err != nil {
		return err
	}
	defer reader.Close()
	
	for _, file := range reader.File {
		path := filepath.Join(dest, file.Name)
		
		// Security check
		if !strings.HasPrefix(path, filepath.Clean(dest)+string(os.PathSeparator)) {
			return fmt.Errorf("invalid file path: %s", file.Name)
		}
		
		if file.FileInfo().IsDir() {
			os.MkdirAll(path, file.FileInfo().Mode())
			continue
		}
		
		if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
			return err
		}
		
		fileReader, err := file.Open()
		if err != nil {
			return err
		}
		defer fileReader.Close()
		
		targetFile, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, file.FileInfo().Mode())
		if err != nil {
			return err
		}
		defer targetFile.Close()
		
		_, err = io.Copy(targetFile, fileReader)
		if err != nil {
			return err
		}
	}
	
	return nil
}

func extractTarGz(src, dest string) error {
	file, err := os.Open(src)
	if err != nil {
		return err
	}
	defer file.Close()
	
	gzr, err := gzip.NewReader(file)
	if err != nil {
		return err
	}
	defer gzr.Close()
	
	tr := tar.NewReader(gzr)
	
	for {
		header, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}
		
		path := filepath.Join(dest, header.Name)
		
		// Security check
		if !strings.HasPrefix(path, filepath.Clean(dest)+string(os.PathSeparator)) {
			return fmt.Errorf("invalid file path: %s", header.Name)
		}
		
		switch header.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(path, 0755); err != nil {
				return err
			}
		case tar.TypeReg:
			if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
				return err
			}
			
			outFile, err := os.Create(path)
			if err != nil {
				return err
			}
			defer outFile.Close()
			
			if _, err := io.Copy(outFile, tr); err != nil {
				return err
			}
		}
	}
	
	return nil
}

func findActualProjectDir(tempDir string) (string, error) {
	// Look for go.mod or .go files to identify the project root
	var candidates []string
	
	err := filepath.Walk(tempDir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		
		if info.IsDir() {
			// Check if this directory contains go.mod or .go files
			entries, err := os.ReadDir(path)
			if err != nil {
				return nil
			}
			
			hasGoFiles := false
			hasGoMod := false
			
			for _, entry := range entries {
				if entry.Name() == "go.mod" {
					hasGoMod = true
					break
				}
				if strings.HasSuffix(entry.Name(), ".go") {
					hasGoFiles = true
				}
			}
			
			if hasGoMod || hasGoFiles {
				candidates = append(candidates, path)
			}
		}
		
		return nil
	})
	
	if err != nil {
		return "", err
	}
	
	if len(candidates) == 0 {
		return tempDir, nil // Return original if no Go project found
	}
	
	// Return the shortest path (likely the root)
	shortest := candidates[0]
	for _, candidate := range candidates[1:] {
		if len(candidate) < len(shortest) {
			shortest = candidate
		}
	}
	
	return shortest, nil
}

func analyzeProject(projectPath string) (*ProjectAnalysis, error) {
	absPath, err := filepath.Abs(projectPath)
	if err != nil {
		return nil, err
	}

	analysis := &ProjectAnalysis{
		MainFiles:       []string{},
		LibraryPackages: []string{},
		Evidence:        []Evidence{},
		ProjectPath:     absPath,
		AnalyzedAt:      time.Now().Format("2006-01-02T15:04:05Z07:00"),
	}

	// Check for go.mod
	analysis.checkGoMod(absPath)
	
	// Check directory structure
	analysis.checkDirectoryStructure(absPath)
	
	// Check for configuration files
	analysis.checkConfigFiles(absPath)

	// Analyze all Go files
	err = filepath.Walk(absPath, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}

		if info.IsDir() {
			name := info.Name()
			// Skip common directories but note important ones
			var skipDirs = map[string]bool{
	          ".git":         true,
	          "example":      true,
			  "examples":     true,
			  "test":         true,
			  "tests":        true,
	          "vendor":       true,
            }

            if name == "." {
            } else if strings.HasPrefix(name, ".") || skipDirs[name] {
            	return filepath.SkipDir
            }
			
			// Calculate package depth
			relPath, _ := filepath.Rel(absPath, path)
			depth := len(strings.Split(relPath, string(os.PathSeparator)))
			if depth > analysis.PackageDepth {
				analysis.PackageDepth = depth
			}
			
			if name == "cmd" {
				analysis.HasCmdDirectory = true
				analysis.addEvidence("structural", "Found cmd/ directory (CLI pattern)", path, 0.9, 0.95)
			}
			if name == "internal" {
				analysis.HasInternalPackages = true
				analysis.addEvidence("structural", "Found internal/ directory (library pattern)", path, 0.7, 0.85)
			}
			return nil
		}

		// Count and analyze different file types
		if strings.HasSuffix(path, ".go") {
			if strings.HasSuffix(path, "_test.go") {
				analysis.TestFiles++
				return analysis.analyzeTestFile(path)
			} else {
				analysis.TotalGoFiles++
				return analysis.analyzeGoFile(path)
			}
		}

		// Check for documentation files
		if strings.ToLower(info.Name()) == "doc.go" {
			analysis.HasDocGo = true
			analysis.addEvidence("library", "Found doc.go file", path, 0.8, 0.85)
		}

		return nil
	})

	if err != nil {
		return nil, err
	}

	// Calculate ratios
	if analysis.TotalGoFiles > 0 {
		mainFiles := len(analysis.MainFiles)
		libraryFiles := analysis.TotalGoFiles - mainFiles
		if libraryFiles > 0 {
			analysis.MainToLibraryRatio = float64(mainFiles) / float64(libraryFiles)
		} else {
			analysis.MainToLibraryRatio = float64(mainFiles)
		}
	}

	// Final determination with improved weighted scoring
	analysis.determineProjectType()
	analysis.TypeString = analysis.Type.String()

	return analysis, nil
}

func (a *ProjectAnalysis) checkGoMod(projectPath string) {
	goModPath := filepath.Join(projectPath, "go.mod")
	if content, err := os.ReadFile(goModPath); err == nil {
		a.HasGoMod = true
		a.addEvidence("metadata", "Found go.mod file", goModPath, 0.4, 0.95)
		
		lines := strings.Split(string(content), "\n")
		for _, line := range lines {
			line = strings.TrimSpace(line)
			if strings.HasPrefix(line, "module ") {
				a.ModuleName = strings.TrimSpace(strings.TrimPrefix(line, "module"))
				
				// Check if module name suggests CLI tool
				if strings.Contains(strings.ToLower(a.ModuleName), "cli") ||
				   strings.Contains(strings.ToLower(a.ModuleName), "tool") ||
				   strings.Contains(strings.ToLower(a.ModuleName), "cmd") {
					a.addEvidence("metadata", "Module name suggests CLI tool", "", 0.6, 0.8)
				}
				break
			}
		}
	}
}

func (a *ProjectAnalysis) checkDirectoryStructure(projectPath string) {
	// Check for common CLI patterns
	cliPaths := []string{"cmd", "cli", "main", "tools", "bin"}
	for _, path := range cliPaths {
		if _, err := os.Stat(filepath.Join(projectPath, path)); err == nil {
			weight := 0.7
			if path == "cmd" {
				weight = 0.9
			}
			a.addEvidence("structural", fmt.Sprintf("Found %s/ directory", path), "", weight, 0.85)
		}
	}
	
	// Check for common library patterns
	libPaths := []string{"pkg", "lib", "internal", "api", "examples", "docs"}
	for _, path := range libPaths {
		if _, err := os.Stat(filepath.Join(projectPath, path)); err == nil {
			weight := 0.6
			if path == "pkg" || path == "internal" {
				weight = 0.8
			}
			a.addEvidence("structural", fmt.Sprintf("Found %s/ directory", path), "", weight, 0.8)
		}
	}
}

func (a *ProjectAnalysis) checkConfigFiles(projectPath string) {
	configFiles := []string{
		".goreleaser.yml", ".goreleaser.yaml",
		"Dockerfile", "docker-compose.yml",
		"Makefile", "makefile",
		"config.yml", "config.yaml", "config.json",
	}
	
	for _, configFile := range configFiles {
		if _, err := os.Stat(filepath.Join(projectPath, configFile)); err == nil {
			a.HasConfigFiles = true
			if strings.Contains(configFile, "goreleaser") {
				a.addEvidence("metadata", "Found .goreleaser config (CLI release tool)", configFile, 0.8, 0.9)
			} else if strings.Contains(configFile, "Docker") || strings.Contains(configFile, "Makefile") {
				a.addEvidence("metadata", fmt.Sprintf("Found %s (deployment/build config)", configFile), configFile, 0.5, 0.7)
			} else {
				a.addEvidence("metadata", fmt.Sprintf("Found %s (application config)", configFile), configFile, 0.6, 0.7)
			}
		}
	}
}

func (a *ProjectAnalysis) analyzeGoFile(filePath string) error {
	fset := token.NewFileSet()
	node, err := parser.ParseFile(fset, filePath, nil, parser.ParseComments)
	if err != nil {
		return nil // Skip unparseable files
	}

	packageName := node.Name.Name
	relPath, _ := filepath.Rel(a.ProjectPath, filePath)

	// Check for go:generate comments
	for _, commentGroup := range node.Comments {
		for _, comment := range commentGroup.List {
			if strings.Contains(comment.Text, "go:generate") {
				a.HasGoGenerate = true
				a.addEvidence("library", "Found go:generate directive", relPath, 0.6, 0.8)
			}
		}
	}

	// Analyze package
	if packageName == "main" {
		a.HasMainPackage = true
		a.addEvidence("package", "Found main package", relPath, 0.9, 0.95)
		
		// Look for main function and other CLI indicators
		a.analyzeMainPackage(node, relPath)
	} else {
		a.HasLibraryPackages = true
		if !contains(a.LibraryPackages, packageName) {
			a.LibraryPackages = append(a.LibraryPackages, packageName)
		}
		a.addEvidence("package", fmt.Sprintf("Found library package: %s", packageName), relPath, 0.7, 0.85)
		
		// Analyze for library patterns
		a.analyzeLibraryPackage(node, packageName, relPath)
	}

	// Check imports for framework usage
	a.analyzeImports(node, relPath)

	return nil
}

func (a *ProjectAnalysis) analyzeMainPackage(node *ast.File, filePath string) {
	hasMainFunc := false
	hasInitFunc := false
	
	for _, decl := range node.Decls {
		switch d := decl.(type) {
		case *ast.FuncDecl:
			funcName := d.Name.Name
			
			switch funcName {
			case "main":
				if d.Recv == nil { // Not a method
					hasMainFunc = true
					a.HasMainFunction = true
					a.MainFiles = append(a.MainFiles, filePath)
					a.addEvidence("function", "Found main() function", filePath, 1.0, 0.99)
					
					// Analyze main function body for CLI patterns
					if d.Body != nil {
						a.analyzeMainFunction(d, filePath)
					}
				}
			case "init":
				hasInitFunc = true
				a.HasMainInit = true
			}
			
			// Check function body for CLI patterns
			if d.Body != nil {
				a.analyzeFunctionForCLIPatterns(d, filePath)
			}
			
		case *ast.GenDecl:
			// Check for version constants or variables
			for _, spec := range d.Specs {
				if valueSpec, ok := spec.(*ast.ValueSpec); ok {
					for _, name := range valueSpec.Names {
						nameStr := strings.ToLower(name.Name)
						if nameStr == "version" || nameStr == "buildversion" || nameStr == "appversion" {
							a.addEvidence("pattern", "Found version constant/variable", filePath, 0.7, 0.8)
						}
					}
				}
			}
		}
	}
	
	if hasMainFunc && hasInitFunc {
		a.addEvidence("pattern", "Main package with init function (CLI setup pattern)", filePath, 0.8, 0.85)
	}
}

func (a *ProjectAnalysis) analyzeMainFunction(funcDecl *ast.FuncDecl, filePath string) {
	hasSubcommands := false
	hasVersionHandling := false
	hasHelpHandling := false
	
	ast.Inspect(funcDecl, func(n ast.Node) bool {
		switch node := n.(type) {
		case *ast.CallExpr:
			if ident, ok := node.Fun.(*ast.SelectorExpr); ok {
				if x, ok := ident.X.(*ast.Ident); ok {
					call := x.Name + "." + ident.Sel.Name
					switch call {
					case "os.Exit":
						a.HasOSExit = true
						a.addEvidence("pattern", "Uses os.Exit() (CLI pattern)", filePath, 0.85, 0.9)
					case "flag.Parse", "flag.String", "flag.Int", "flag.Bool":
						a.HasFlagUsage = true
						a.addEvidence("pattern", "Uses flag package (CLI pattern)", filePath, 0.9, 0.95)
					case "fmt.Println", "fmt.Printf", "fmt.Print":
						a.addEvidence("pattern", "Uses fmt output functions", filePath, 0.4, 0.7)
					}
				}
			}
		case *ast.BasicLit:
			if node.Kind == token.STRING {
				value := strings.ToLower(node.Value)
				if strings.Contains(value, "version") || strings.Contains(value, "-v") {
					hasVersionHandling = true
				}
				if strings.Contains(value, "help") || strings.Contains(value, "-h") || strings.Contains(value, "usage") {
					hasHelpHandling = true
					a.HasHelpText = true
				}
				if strings.Contains(value, "command") || strings.Contains(value, "subcommand") {
					hasSubcommands = true
				}
			}
		case *ast.SwitchStmt:
			// Switch statements in main often indicate subcommand handling
			hasSubcommands = true
		}
		return true
	})
	
	if hasVersionHandling {
		a.HasVersionFlag = true
		a.addEvidence("pattern", "Version flag handling detected", filePath, 0.8, 0.85)
	}
	if hasHelpHandling {
		a.addEvidence("pattern", "Help text detected", filePath, 0.7, 0.8)
	}
	if hasSubcommands {
		a.HasSubcommands = true
		a.addEvidence("pattern", "Subcommand handling detected", filePath, 0.9, 0.9)
	}
}

func (a *ProjectAnalysis) analyzeLibraryPackage(node *ast.File, packageName, filePath string) {
	exportedFuncs := 0
	exportedTypes := 0
	exportedVars := 0
	exportedConsts := 0
	interfaces := 0
	
	for _, decl := range node.Decls {
		switch d := decl.(type) {
		case *ast.FuncDecl:
			if d.Name.IsExported() {
				exportedFuncs++
				a.HasExportedSymbols = true
				a.ExportedSymbolCount++
			}
		case *ast.GenDecl:
			for _, spec := range d.Specs {
				switch s := spec.(type) {
				case *ast.TypeSpec:
					if s.Name.IsExported() {
						exportedTypes++
						a.HasExportedSymbols = true
						a.HasTypeDefinitions = true
						a.ExportedSymbolCount++
						
						// Check if it's an interface
						if _, isInterface := s.Type.(*ast.InterfaceType); isInterface {
							interfaces++
							a.HasInterfaces = true
						}
					}
				case *ast.ValueSpec:
					for _, name := range s.Names {
						if name.IsExported() {
							if d.Tok == token.CONST {
								exportedConsts++
								a.HasConstants = true
							} else {
								exportedVars++
							}
							a.HasExportedSymbols = true
							a.ExportedSymbolCount++
						}
					}
				}
			}
		}
	}
	
	if exportedFuncs > 0 || exportedTypes > 0 || exportedVars > 0 || exportedConsts > 0 {
		a.HasPublicAPI = true
		totalExported := exportedFuncs + exportedTypes + exportedVars + exportedConsts
		confidence := 0.7 + float64(totalExported)/20.0
		if confidence > 0.95 {
			confidence = 0.95
		}
		weight := 0.8
		if totalExported > 5 {
			weight = 0.9
		}
		a.addEvidence("api", 
			fmt.Sprintf("Package %s has %d exported symbols", packageName, totalExported), 
			filePath, weight, confidence)
	}
	
	if interfaces > 0 {
		confidence := 0.8 + float64(interfaces)/10.0
		if confidence > 0.95 {
			confidence = 0.95
		}
		a.addEvidence("pattern", fmt.Sprintf("Package %s defines %d interface(s)", packageName, interfaces), filePath, 0.8, confidence)
	}
	
	if exportedConsts > 0 {
		a.addEvidence("pattern", fmt.Sprintf("Package %s has %d exported constants", packageName, exportedConsts), filePath, 0.7, 0.8)
	}
}

func (a *ProjectAnalysis) analyzeFunctionForCLIPatterns(funcDecl *ast.FuncDecl, filePath string) {
	hasStdinReading := false
	hasFileOperations := false
	
	ast.Inspect(funcDecl, func(n ast.Node) bool {
		switch node := n.(type) {
		case *ast.CallExpr:
			if ident, ok := node.Fun.(*ast.SelectorExpr); ok {
				if x, ok := ident.X.(*ast.Ident); ok {
					call := x.Name + "." + ident.Sel.Name
					switch call {
					case "os.Exit":
						a.HasOSExit = true
						a.addEvidence("pattern", "Uses os.Exit() (CLI pattern)", filePath, 0.85, 0.9)
					case "flag.Parse", "flag.String", "flag.Int", "flag.Bool", "flag.Duration":
						a.HasFlagUsage = true
						a.addEvidence("pattern", "Uses flag package (CLI pattern)", filePath, 0.9, 0.95)
					case "fmt.Println", "fmt.Printf", "fmt.Print", "fmt.Fprint", "fmt.Fprintf":
						a.addEvidence("pattern", "Uses fmt output functions", filePath, 0.4, 0.7)
					case "os.Stdin", "bufio.NewScanner", "bufio.NewReader":
						hasStdinReading = true
					case "os.Open", "os.Create", "os.OpenFile", "ioutil.ReadFile", "os.ReadFile":
						hasFileOperations = true
					case "log.Fatal", "log.Fatalf":
						a.addEvidence("pattern", "Uses log.Fatal (CLI error handling)", filePath, 0.7, 0.8)
					}
				}
			}
		case *ast.Ident:
			if node.Name == "os.Stdin" {
				hasStdinReading = true
			}
		}
		return true
	})
	
	if hasStdinReading {
		a.HasStdinReading = true
		a.addEvidence("pattern", "Reads from stdin (CLI pattern)", filePath, 0.8, 0.85)
	}
	if hasFileOperations {
		a.addEvidence("pattern", "File operations detected", filePath, 0.5, 0.7)
	}
}

func (a *ProjectAnalysis) analyzeImports(node *ast.File, filePath string) {
	for _, imp := range node.Imports {
		if imp.Path != nil {
			path := strings.Trim(imp.Path.Value, `"`)
			
			// CLI framework detection
			cliFrameworks := map[string]float64{
				"alecthomas/kingpin":  0.92,
				"alecthomas/kingpin/v2": 0.92,
				"docopt/docopt-go":    0.85,
				"flag":                0.75,
				"jessevdk/go-flags":   0.88,
				"spf13/cobra":         0.98,
				"urfave/cli":          0.97,
				"urfave/cli/v2":       0.97,
			}
			
			if weight, isCLI := cliFrameworks[path]; isCLI {
				if strings.Contains(path, "cobra") {
					a.HasCobraUsage = true
				}
				confidence := 0.95
				if path == "flag" {
					confidence = 0.8
				}
				a.addEvidence("import", fmt.Sprintf("Imports CLI framework: %s", path), filePath, weight, confidence)
			}
			
			// Library-specific imports
			if strings.Contains(path, "/internal/") {
				a.addEvidence("import", "Uses internal packages (library pattern)", filePath, 0.7, 0.8)
			}
			
			// Testing and documentation frameworks (library indicators)
			testFrameworks := map[string]float64{
				"stretchr/testify":    0.7,
				"onsi/ginkgo":         0.7,
				"onsi/gomega":         0.7,
				"gopkg.in/check.v1":   0.6,
			}
			
			if weight, isTest := testFrameworks[path]; isTest {
				a.addEvidence("import", fmt.Sprintf("Imports testing framework: %s", path), filePath, weight, 0.8)
			}
			
			// Web frameworks (library indicators)
			webFrameworks := []string{
				"gin-gonic/gin",
				"gorilla/mux",
				"labstack/echo",
				"go-chi/chi",
				"net/http",
			}
			
			for _, framework := range webFrameworks {
				if path == framework {
					weight := 0.8
					if framework == "net/http" {
						weight = 0.6
					}
					a.addEvidence("import", fmt.Sprintf("Imports web framework: %s", path), filePath, weight, 0.8)
				}
			}
			
			// Database libraries (often library indicators)
			dbLibraries := []string{
				"database/sql",
				"jinzhu/gorm",
				"gorm.io/gorm",
				"jmoiron/sqlx",
			}
			
			for _, db := range dbLibraries {
				if path == db {
					a.addEvidence("import", fmt.Sprintf("Imports database library: %s", path), filePath, 0.6, 0.7)
				}
			}
		}
	}
}

func (a *ProjectAnalysis) analyzeTestFile(filePath string) error {
	fset := token.NewFileSet()
	node, err := parser.ParseFile(fset, filePath, nil, parser.ParseComments)
	if err != nil {
		return nil
	}

	hasExampleTests := false
	hasBenchmarkTests := false
	
	// Look for example tests and benchmark tests
	for _, decl := range node.Decls {
		if funcDecl, ok := decl.(*ast.FuncDecl); ok {
			funcName := funcDecl.Name.Name
			if strings.HasPrefix(funcName, "Example") {
				hasExampleTests = true
				a.HasExampleTests = true
			}
			if strings.HasPrefix(funcName, "Benchmark") {
				hasBenchmarkTests = true
				a.HasBenchmarkTests = true
			}
		}
	}
	
	relPath, _ := filepath.Rel(a.ProjectPath, filePath)
	
	if hasExampleTests {
		a.addEvidence("test", "Found example test (library documentation pattern)", relPath, 0.85, 0.9)
	}
	if hasBenchmarkTests {
		a.addEvidence("test", "Found benchmark test (library performance pattern)", relPath, 0.8, 0.85)
	}

	return nil
}

func (a *ProjectAnalysis) determineProjectType() {
	cliScore := 0.0
	libraryScore := 0.0
	
	// Weight evidence with improved scoring
	for _, evidence := range a.Evidence {
		weight := evidence.Weight * evidence.Confidence
		
		switch evidence.Type {
		case "function":
			if strings.Contains(evidence.Description, "main()") {
				cliScore += weight * 2.5 // Main function is very strong CLI indicator
			}
		case "package":
			if strings.Contains(evidence.Description, "main package") {
				cliScore += weight * 2.0
			} else {
				libraryScore += weight * 1.2
			}
		case "pattern":
			if strings.Contains(evidence.Description, "CLI") || 
			   strings.Contains(evidence.Description, "os.Exit") ||
			   strings.Contains(evidence.Description, "flag") ||
			   strings.Contains(evidence.Description, "stdin") ||
			   strings.Contains(evidence.Description, "Subcommand") ||
			   strings.Contains(evidence.Description, "Version flag") ||
			   strings.Contains(evidence.Description, "Help text") {
				cliScore += weight * 1.3
			} else if strings.Contains(evidence.Description, "interface") ||
					  strings.Contains(evidence.Description, "constants") {
				libraryScore += weight * 1.1
			} else {
				libraryScore += weight
			}
		case "import":
			if strings.Contains(evidence.Description, "CLI framework") {
				multiplier := 1.8
				if strings.Contains(evidence.Description, "cobra") || strings.Contains(evidence.Description, "urfave") {
					multiplier = 2.2
				}
				cliScore += weight * multiplier
			} else if strings.Contains(evidence.Description, "web framework") ||
					  strings.Contains(evidence.Description, "testing framework") ||
					  strings.Contains(evidence.Description, "database") {
				libraryScore += weight * 1.2
			} else {
				libraryScore += weight
			}
		case "api":
			libraryScore += weight * 1.5 // Exported symbols are strong library indicators
		case "structural":
			if strings.Contains(evidence.Description, "cmd/") {
				cliScore += weight * 1.4
			} else {
				libraryScore += weight * 1.1
			}
		case "test":
			libraryScore += weight * 1.2
		case "library":
			libraryScore += weight * 1.3
		case "metadata":
			if strings.Contains(evidence.Description, "CLI") ||
			   strings.Contains(evidence.Description, "goreleaser") {
				cliScore += weight
			} else {
				// Neutral metadata
				if strings.Contains(evidence.Description, "go.mod") {
					// go.mod is slightly more common in libraries but not decisive
					libraryScore += weight * 0.3
				}
			}
		}
	}
	
	// Additional scoring based on structural analysis
	redundantCLIChecks := 0
	redundantLibraryChecks := 0
	
	// CLI redundant indicators with weighted importance
	if a.HasMainFunction { redundantCLIChecks += 3 }
	if a.HasMainPackage { redundantCLIChecks += 2 }
	if a.HasFlagUsage { redundantCLIChecks += 2 }
	if a.HasCobraUsage { redundantCLIChecks += 3 }
	if a.HasOSExit { redundantCLIChecks += 2 }
	if a.HasCmdDirectory { redundantCLIChecks += 2 }
	if a.HasSubcommands { redundantCLIChecks += 2 }
	if a.HasVersionFlag { redundantCLIChecks += 1 }
	if a.HasHelpText { redundantCLIChecks += 1 }
	if a.HasStdinReading { redundantCLIChecks += 1 }
	
	// Library redundant indicators with weighted importance
	if a.HasExportedSymbols { redundantLibraryChecks += 2 }
	if a.HasPublicAPI { redundantLibraryChecks += 2 }
	if a.HasInterfaces { redundantLibraryChecks += 2 }
	if a.HasDocGo { redundantLibraryChecks += 2 }
	if a.HasExampleTests { redundantLibraryChecks += 2 }
	if a.HasBenchmarkTests { redundantLibraryChecks += 1 }
	if a.HasInternalPackages { redundantLibraryChecks += 1 }
	if a.HasGoGenerate { redundantLibraryChecks += 1 }
	if a.HasConstants { redundantLibraryChecks += 1 }
	if a.HasTypeDefinitions { redundantLibraryChecks += 1 }
	if len(a.LibraryPackages) > 2 { redundantLibraryChecks += 2 }
	if a.ExportedSymbolCount > 10 { redundantLibraryChecks += 2 }
	if a.PackageDepth > 2 { redundantLibraryChecks += 1 }
	
	// Apply structural bonuses
	cliScore += float64(redundantCLIChecks) * 0.4
	libraryScore += float64(redundantLibraryChecks) * 0.3
	
	// Ratio-based adjustments
	if a.MainToLibraryRatio > 0.8 {
		cliScore += 2.0
	} else if a.MainToLibraryRatio < 0.2 && a.MainToLibraryRatio > 0 {
		libraryScore += 1.5
	}
	
	// File count considerations
	if a.TotalGoFiles == 1 && len(a.MainFiles) == 1 {
		cliScore += 1.0 // Single main file suggests CLI
	}
	if a.TestFiles > 3 {
		libraryScore += 1.0 // Many tests suggest library
	}
	
	totalScore := cliScore + libraryScore
	if totalScore == 0 {
		a.Type = Unclear
		a.Confidence = 0.0
		return
	}
	
	// Determine type with enhanced logic
	cliThreshold := 1.3
	libraryThreshold := 1.2
	
	if cliScore > libraryScore*cliThreshold && redundantCLIChecks >= 3 {
		a.Type = CLI
		a.Confidence = cliScore / totalScore
	} else if libraryScore > cliScore*libraryThreshold && redundantLibraryChecks >= 3 {
		a.Type = Library
		a.Confidence = libraryScore / totalScore
	} else if cliScore > libraryScore && redundantCLIChecks >= 2 {
		a.Type = CLI
		a.Confidence = (cliScore / totalScore) * 0.85
	} else if libraryScore > cliScore && redundantLibraryChecks >= 2 {
		a.Type = Library
		a.Confidence = (libraryScore / totalScore) * 0.85
	} else if cliScore > libraryScore {
		a.Type = CLI
		a.Confidence = (cliScore / totalScore) * 0.7
	} else if libraryScore > cliScore {
		a.Type = Library
		a.Confidence = (libraryScore / totalScore) * 0.7
	} else {
		a.Type = Unclear
		a.Confidence = 0.5
	}
	
	// Cap confidence at reasonable levels
	if a.Confidence > 0.98 {
		a.Confidence = 0.98
	}
	if a.Confidence < 0.1 {
		a.Confidence = 0.1
	}
}

func (a *ProjectAnalysis) addEvidence(evidenceType, description, file string, weight, confidence float64) {
	a.Evidence = append(a.Evidence, Evidence{
		Type:        evidenceType,
		Description: description,
		File:        file,
		Weight:      weight,
		Confidence:  confidence,
	})
}

func printHumanReadable(analysis *ProjectAnalysis) {
	// Calculate scores for different categories
	mainPackageScore := 0
	if analysis.HasMainFunction {
		mainPackageScore = len(analysis.MainFiles) * 5
	}
	
	dirScore := 0
	if analysis.HasCmdDirectory { dirScore += 4 }
	if analysis.HasInternalPackages { dirScore += 2 }
	if analysis.HasLibraryPackages { dirScore += 1 }
	
	execScore := 0
	if analysis.HasFlagUsage { execScore += 3 }
	if analysis.HasCobraUsage { execScore += 4 }
	if analysis.HasOSExit { execScore += 2 }
	if analysis.HasSubcommands { execScore += 3 }
	if analysis.HasVersionFlag { execScore += 1 }
	if analysis.HasStdinReading { execScore += 2 }
	
	libScore := 0
	if analysis.HasExportedSymbols { libScore += 3 }
	if analysis.HasInterfaces { libScore += 2 }
	if analysis.HasExampleTests { libScore += 2 }
	if analysis.HasDocGo { libScore += 2 }
	if analysis.ExportedSymbolCount > 5 { libScore += 2 }
	
	totalScore := mainPackageScore + dirScore + execScore + libScore
	
	// Color codes
	green := "\033[32m"
	blue := "\033[34m" 
	yellow := "\033[33m"
	cyan := "\033[36m"
	magenta := "\033[35m"
	red := "\033[31m"
	bold := "\033[1m"
	dim := "\033[2m"
	nc := "\033[0m" // No Color
	
	fmt.Println()
	if analysis.IsRemote {
		fmt.Fprintf(os.Stderr, "%s=== REMOTE ANALYSIS RESULTS ===%s\n", cyan, nc)
		fmt.Fprintf(os.Stderr, "%sSource: %s%s\n", dim, analysis.RemoteSource, nc)
	} else {
		fmt.Fprintf(os.Stderr, "%s=== ANALYSIS RESULTS ===%s\n", cyan, nc)
	}
	
	fmt.Fprintf(os.Stderr, "%sMain package indicators:%s %d (×5 = %d points)\n", dim, nc, len(analysis.MainFiles), mainPackageScore)
	fmt.Fprintf(os.Stderr, "%sDirectory structure score:%s %d points\n", dim, nc, dirScore)
	fmt.Fprintf(os.Stderr, "%sExecutable indicators:%s %d points\n", dim, nc, execScore)
	fmt.Fprintf(os.Stderr, "%sLibrary indicators:%s %d points\n", dim, nc, libScore)
	fmt.Fprintf(os.Stderr, "%sExported symbols:%s %d\n", dim, nc, analysis.ExportedSymbolCount)
	fmt.Fprintf(os.Stderr, "%sPackage depth:%s %d\n", dim, nc, analysis.PackageDepth)
	if analysis.MainToLibraryRatio > 0 {
		fmt.Fprintf(os.Stderr, "%sMain/Library ratio:%s %.2f\n", dim, nc, analysis.MainToLibraryRatio)
	}
	fmt.Fprintf(os.Stderr, "----------------------------------------\n")
	fmt.Fprintf(os.Stderr, "%sTotal score:%s %d points\n", bold, nc, totalScore)
	fmt.Fprintf(os.Stderr, "\n")
	
	confidence := fmt.Sprintf("%.1f%%", analysis.Confidence*100)
	projectPath := analysis.ProjectPath
	
	switch analysis.Type {
	case CLI:
		fmt.Fprintf(os.Stderr, "%s🔧 RESULT: %s%s%sCLI TOOL%s %s==> %s%s%s\n", 
			green, bold, cyan, nc, nc, dim, cyan, projectPath, nc)
		fmt.Fprintf(os.Stderr, "%sConfidence: %s%s%s%s\n", 
			dim, bold, green, confidence, nc)
			
		// Show key CLI indicators
		indicators := []string{}
		if analysis.HasMainFunction { indicators = append(indicators, "main()") }
		if analysis.HasCobraUsage { indicators = append(indicators, "Cobra") }
		if analysis.HasFlagUsage { indicators = append(indicators, "flags") }
		if analysis.HasSubcommands { indicators = append(indicators, "subcommands") }
		if analysis.HasCmdDirectory { indicators = append(indicators, "cmd/") }
		if len(indicators) > 0 {
			fmt.Fprintf(os.Stderr, "%sKey indicators: %s%s\n", dim, strings.Join(indicators, ", "), nc)
		}
		
	case Library:
		fmt.Fprintf(os.Stderr, "%s📚 RESULT: %s%s%sLIBRARY%s %s==> %s%s%s\n", 
			blue, bold, magenta, nc, nc, dim, cyan, projectPath, nc)
		fmt.Fprintf(os.Stderr, "%sConfidence: %s%s%s%s\n", 
			dim, bold, green, confidence, nc)
			
		// Show key library indicators
		indicators := []string{}
		if analysis.HasExportedSymbols { indicators = append(indicators, fmt.Sprintf("%d exports", analysis.ExportedSymbolCount)) }
		if analysis.HasInterfaces { indicators = append(indicators, "interfaces") }
		if analysis.HasExampleTests { indicators = append(indicators, "examples") }
		if analysis.HasDocGo { indicators = append(indicators, "doc.go") }
		if len(analysis.LibraryPackages) > 1 { indicators = append(indicators, fmt.Sprintf("%d packages", len(analysis.LibraryPackages))) }
		if len(indicators) > 0 {
			fmt.Fprintf(os.Stderr, "%sKey indicators: %s%s\n", dim, strings.Join(indicators, ", "), nc)
		}
		
	default:
		fmt.Fprintf(os.Stderr, "%s❓ RESULT: %s%s%sUNCLEAR%s %s==> %s%s%s\n", 
			yellow, bold, yellow, nc, nc, dim, cyan, projectPath, nc)
		fmt.Fprintf(os.Stderr, "%sConfidence: %s%s%s%s\n", 
			dim, bold, yellow, confidence, nc)
		fmt.Fprintf(os.Stderr, "%sCould be either a library or CLI tool. Manual inspection recommended.%s\n", red, nc)
		
		// Show what we found
		if analysis.HasMainFunction && analysis.HasExportedSymbols {
			fmt.Fprintf(os.Stderr, "%sFound both main() function and exported symbols%s\n", dim, nc)
		}
	}
	
	if *verbose && !*jsonOutput {
		fmt.Fprintf(os.Stderr, "\n%sDetailed Evidence:%s\n", bold, nc)
		for i, evidence := range analysis.Evidence {
			if i >= 10 { // Limit output
				fmt.Fprintf(os.Stderr, "%s... and %d more pieces of evidence%s\n", dim, len(analysis.Evidence)-i, nc)
				break
			}
			fmt.Fprintf(os.Stderr, "%s[%s] %s (%.2f/%.2f)%s\n", 
				dim, evidence.Type, evidence.Description, evidence.Weight, evidence.Confidence, nc)
		}
	}
}

func contains(slice []string, item string) bool {
	for _, s := range slice {
		if s == item {
			return true
		}
	}
	return false
}