#!/usr/bin/env -S uv run --script
# /// script
# dependencies = [
#   "aiohttp>=3.9.0",
# ]
# ///
"""
Generic parallelized batch downloader.
Handles batch processing with configurable delays and concurrent requests.
Supports different content types (JSON, KML, etc.) with appropriate validation.
"""

import asyncio
import aiohttp
import json
import os
import sys
import random
import argparse
import ssl
import shutil
from pathlib import Path
from typing import List, Tuple, Optional
import time
from datetime import datetime

class ParallelDownloader:
    def __init__(self, min_batch_size=5, max_batch_size=20, min_delay=1.0, max_delay=5.0, max_concurrent=10, content_type='json', http_method='POST', timestamp_file=None, staging_root=None):
        self.min_batch_size = min_batch_size
        self.max_batch_size = max_batch_size
        self.min_delay = min_delay
        self.max_delay = max_delay
        self.max_concurrent = max_concurrent
        self.content_type = content_type.lower()
        self.http_method = http_method.upper()
        self.semaphore = asyncio.Semaphore(max_concurrent)
        self.timestamp_file = timestamp_file
        self.staging_root = Path(staging_root) if staging_root else None
        self.timestamps_data = {}
        
        # Load timestamp data if provided
        if timestamp_file and os.path.exists(timestamp_file):
            self._load_timestamps()
        
        # Stats tracking
        self.downloaded = 0
        self.skipped = 0
        self.failed = 0
        self.force_redownloaded = 0
        self.max_5xx_retries = 5
        self.retry_delay_seconds = 2.0
        
    def _load_timestamps(self):
        """Load timestamp data from JSON file"""
        try:
            with open(self.timestamp_file, 'r') as f:
                data = json.load(f)
                # Extract timestamps for each proposal ID
                for item in data.get('data', []):
                    if item.get('id') and item.get('app_updated_on'):
                        self.timestamps_data[str(item['id'])] = item['app_updated_on']
        except Exception as e:
            print(f"Warning: Could not load timestamps from {self.timestamp_file}: {e}")
    
    def _should_redownload_file(self, output_path: str) -> bool:
        """Check if file should be re-downloaded based on timestamp comparison"""
        if not self.timestamps_data:
            return False
            
        # Extract proposal_id from filename
        filename = os.path.basename(output_path)
        proposal_id = filename.replace('.json', '')
        
        if proposal_id not in self.timestamps_data:
            return False
            
        try:
            # Get current timestamp from search data
            current_timestamp = self.timestamps_data[proposal_id]
            
            # Try to get timestamp from existing file
            if os.path.exists(output_path):
                with open(output_path, 'r') as f:
                    existing_data = json.load(f)
                    
                # Check various possible timestamp fields in the existing file
                existing_timestamp = None
                for field in ['app_updated_on', 'Application Updated On', 'updated_on']:
                    if field in existing_data:
                        existing_timestamp = existing_data[field]
                        break
                
                if existing_timestamp:
                    # Parse timestamps and compare
                    try:
                        current_dt = datetime.fromisoformat(current_timestamp.replace('Z', '+00:00'))
                        existing_dt = datetime.fromisoformat(existing_timestamp.replace('Z', '+00:00'))
                        
                        if current_dt > existing_dt:
                            print(f"  Re-downloading {proposal_id}: updated {existing_timestamp} -> {current_timestamp}")
                            return True
                    except ValueError:
                        # If timestamp parsing fails, play it safe and re-download
                        return True
            
        except Exception as e:
            print(f"Warning: Error checking timestamp for {proposal_id}: {e}")
            # If we can't determine, don't re-download to avoid unnecessary load
            return False
            
        return False
        
    def parse_url_file(self, url_file_path: str) -> List[Tuple[str, str]]:
        """Parse URL file with format: url output_path"""
        urls_and_paths = []
        
        try:
            with open(url_file_path, 'r') as f:
                for line_num, line in enumerate(f, 1):
                    line = line.strip()
                    if not line or line.startswith('#'):
                        continue
                    
                    parts = line.split('\t')
                    if len(parts) != 2:
                        print(f"Warning: Skipping malformed line {line_num}: {line}")
                        continue
                    
                    url, output_path = parts
                    urls_and_paths.append((url.strip(), output_path.strip()))
                    
        except FileNotFoundError:
            print(f"Error: URL file {url_file_path} not found")
            sys.exit(1)
        except Exception as e:
            print(f"Error reading URL file: {e}")
            sys.exit(1)
            
        return urls_and_paths
    
    def validate_file_content(self, file_path: str) -> bool:
        """Validate file content based on content type"""
        try:
            with open(file_path, 'r', encoding='utf-8') as f:
                content = f.read()
            
            if self.content_type == 'json':
                json.loads(content)
                return True
            elif self.content_type == 'kml':
                # Basic KML validation - check for KML tags
                return '<kml' in content.lower() or '<placemark' in content.lower()
            else:
                # For other content types, just check if file has content
                return len(content.strip()) > 0
                
        except (json.JSONDecodeError, IOError, UnicodeDecodeError):
            return False
    
    def filter_existing_files(self, urls_and_paths: List[Tuple[str, str]]) -> List[Tuple[str, str]]:
        """Filter out URLs where output files already exist and are valid, considering timestamps"""
        filtered = []
        
        for url, output_path in urls_and_paths:
            file_exists = os.path.exists(output_path) and os.path.getsize(output_path) > 0
            
            # Check if file should be re-downloaded due to timestamp update
            should_redownload = self._should_redownload_file(output_path)
            
            if file_exists and self.validate_file_content(output_path) and not should_redownload:
                self.skipped += 1
                continue
            elif file_exists and should_redownload:
                self.force_redownloaded += 1
            
            filtered.append((url, output_path))
        
        return filtered

    def get_staging_path(self, output_path: str) -> str:
        """Return the staging path for an output file."""
        if self.staging_root is None:
            return f"{output_path}.tmp"

        output = Path(output_path)
        if output.is_absolute():
            relative_output = output.relative_to(output.anchor)
        else:
            relative_output = output

        return str(self.staging_root / relative_output)
    
    async def download_single(self, session: aiohttp.ClientSession, url: str, output_path: str) -> bool:
        """Download a single file with retry logic"""
        async with self.semaphore:
            temp_path = self.get_staging_path(output_path)
            
            try:
                # Ensure output directory exists
                output_dir = os.path.dirname(output_path)
                if output_dir:  # Only create if there's actually a directory part
                    os.makedirs(output_dir, exist_ok=True)
                staging_dir = os.path.dirname(temp_path)
                if staging_dir:
                    os.makedirs(staging_dir, exist_ok=True)
                
                # Use appropriate HTTP method
                request_method = session.post if self.http_method == 'POST' else session.get
                for attempt in range(self.max_5xx_retries + 1):
                    async with request_method(url) as response:
                        if response.status == 200:
                            content = await response.text()
                            
                            # Validate content based on content type
                            if self.content_type == 'json':
                                try:
                                    json.loads(content)
                                except json.JSONDecodeError:
                                    print(f"Warning: Invalid JSON from {url}")
                                    return False
                            elif self.content_type == 'kml':
                                if not ('<kml' in content.lower() or '<placemark' in content.lower()):
                                    print(f"Warning: Invalid KML content from {url}")
                                    return False
                            
                            # Write to temp file first, then move
                            with open(temp_path, 'w') as f:
                                f.write(content)
                            
                            shutil.move(temp_path, output_path)
                            self.downloaded += 1
                            return True

                        if 500 <= response.status <= 599 and attempt < self.max_5xx_retries:
                            print(
                                f"HTTP {response.status} for {url}; "
                                f"retrying in {self.retry_delay_seconds:.1f}s "
                                f"({attempt + 1}/{self.max_5xx_retries})"
                            )
                            await asyncio.sleep(self.retry_delay_seconds)
                            continue

                        print(f"HTTP {response.status} for {url}")
                        return False
                         
            except Exception as e:
                print(f"Error downloading {url}: {e}")
                # Clean up temp file
                if os.path.exists(temp_path):
                    os.remove(temp_path)
                return False
    
    async def download_batch(self, session: aiohttp.ClientSession, batch: List[Tuple[str, str]]):
        """Download a batch of files concurrently"""
        tasks = []
        for url, output_path in batch:
            task = asyncio.create_task(self.download_single(session, url, output_path))
            tasks.append(task)
        
        results = await asyncio.gather(*tasks, return_exceptions=True)
        
        # Count failures
        for result in results:
            if isinstance(result, Exception) or result is False:
                self.failed += 1
    
    async def process_downloads(self, urls_and_paths: List[Tuple[str, str]]):
        """Process all downloads in randomized batches"""
        if not urls_and_paths:
            print("No files to download")
            return
        
        print(f"Processing {len(urls_and_paths)} downloads...")
        
        # Create session with reasonable timeout and SSL context
        timeout = aiohttp.ClientTimeout(total=30, connect=10)
        # Create SSL context that doesn't verify certificates (like curl without --cacert)
        ssl_context = ssl.create_default_context()
        ssl_context.check_hostname = False
        ssl_context.verify_mode = ssl.CERT_NONE
        connector = aiohttp.TCPConnector(limit=50, limit_per_host=20, ssl=ssl_context)
        
        async with aiohttp.ClientSession(timeout=timeout, connector=connector) as session:
            # Process in random batches
            remaining = urls_and_paths.copy()
            batch_num = 0
            
            while remaining:
                batch_num += 1
                # Ensure batch size is valid - min_batch_size cannot exceed remaining files
                effective_min_batch = min(self.min_batch_size, len(remaining))
                effective_max_batch = min(self.max_batch_size, len(remaining))
                batch_size = random.randint(effective_min_batch, effective_max_batch)
                
                # Take random sample for this batch
                batch = random.sample(remaining, batch_size)
                for item in batch:
                    remaining.remove(item)
                
                print(f"Batch {batch_num}: Processing {len(batch)} files ({len(remaining)} remaining)")
                
                start_time = time.time()
                await self.download_batch(session, batch)
                batch_time = time.time() - start_time
                
                print(f"  Batch completed in {batch_time:.1f}s")
                
                # Random delay between batches (except for the last batch)
                if remaining:
                    delay = random.uniform(self.min_delay, self.max_delay)
                    print(f"  Waiting {delay:.1f}s before next batch...")
                    await asyncio.sleep(delay)

def main():
    parser = argparse.ArgumentParser(description='Generic parallel batch downloader')
    parser.add_argument('url_file', help='File containing URLs and output paths (tab-separated)')
    parser.add_argument('--min-batch-size', type=int, default=5, help='Minimum batch size (default: 5)')
    parser.add_argument('--max-batch-size', type=int, default=20, help='Maximum batch size (default: 20)')
    parser.add_argument('--min-delay', type=float, default=1.0, help='Minimum delay between batches in seconds (default: 1.0)')
    parser.add_argument('--max-delay', type=float, default=5.0, help='Maximum delay between batches in seconds (default: 5.0)')
    parser.add_argument('--max-concurrent', type=int, default=10, help='Maximum concurrent downloads (default: 10)')
    parser.add_argument('--content-type', type=str, default='json', choices=['json', 'kml'], help='Content type for validation (default: json)')
    parser.add_argument('--http-method', type=str, default='POST', choices=['GET', 'POST'], help='HTTP method to use (default: POST)')
    parser.add_argument('--timestamp-file', type=str, help='JSON file containing timestamp data for comparison')
    parser.add_argument('--staging-root', type=str, help='Directory used for staged downloads before moving into place')
    
    args = parser.parse_args()
    
    downloader = ParallelDownloader(
        min_batch_size=args.min_batch_size,
        max_batch_size=args.max_batch_size,
        min_delay=args.min_delay,
        max_delay=args.max_delay,
        max_concurrent=args.max_concurrent,
        content_type=args.content_type,
        http_method=args.http_method,
        timestamp_file=args.timestamp_file,
        staging_root=args.staging_root
    )
    
    # Parse URLs
    print(f"Reading URLs from {args.url_file}...")
    urls_and_paths = downloader.parse_url_file(args.url_file)
    print(f"Found {len(urls_and_paths)} URLs")
    
    # Filter existing files
    print("Filtering existing valid files...")
    if downloader.timestamp_file:
        print(f"Using timestamp file: {downloader.timestamp_file}")
        print(f"Loaded {len(downloader.timestamps_data)} timestamp entries")
    urls_to_download = downloader.filter_existing_files(urls_and_paths)
    print(f"Skipped {downloader.skipped} existing files")
    if downloader.force_redownloaded > 0:
        print(f"Force re-downloading {downloader.force_redownloaded} files due to timestamp updates")
    print(f"Need to download {len(urls_to_download)} files")
    
    if urls_to_download:
        # Run the downloads
        asyncio.run(downloader.process_downloads(urls_to_download))
    
    # Print final stats
    print("\nDownload Summary:")
    print(f"  Downloaded: {downloader.downloaded}")
    print(f"  Skipped (existing): {downloader.skipped}")
    if downloader.force_redownloaded > 0:
        print(f"  Force re-downloaded (timestamp updates): {downloader.force_redownloaded}")
    print(f"  Failed: {downloader.failed}")
    print(f"  Total processed: {downloader.downloaded + downloader.skipped + downloader.failed}")

if __name__ == "__main__":
    main()
