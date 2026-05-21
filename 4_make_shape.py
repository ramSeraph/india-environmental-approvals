#!/usr/bin/env python3
"""
make_shape.py - Convert CSV environmental approvals data to GeoJSON with existing KML files
"""

import asyncio
import os
import sys
import csv
import json
import hashlib
import tempfile
import urllib.parse
from pathlib import Path
from typing import Dict, List, Any, Optional, Tuple
from xml.etree import ElementTree as ET

from request import ParallelDownloader

SHAPE_CACHE_VERSION = 1

def generate_kml_filename(url: str) -> str:
    """Generate filename from KML URL parameters"""
    try:
        parsed_url = urllib.parse.urlparse(url)
        query_params = urllib.parse.parse_qs(parsed_url.query)
        
        # Use refId and uuid for unique filename
        ref_id = query_params.get('refId', ['unknown'])[0]
        uuid = query_params.get('uuid', ['unknown'])[0][:8]  # First 8 chars of UUID
        return f"{ref_id}_{uuid}.kml"
    except:
        # Fallback to hash of URL if parsing fails
        import hashlib
        return f"kml_{hashlib.md5(url.encode()).hexdigest()[:8]}.kml"

def collect_kml_downloads(csv_path: str, kml_dir: Path) -> List[Tuple[str, str]]:
    """Collect KML download URLs and destination paths from the CSV."""
    downloads: List[Tuple[str, str]] = []

    with open(csv_path, 'r', encoding='utf-8') as csvfile:
        reader = csv.DictReader(csvfile)

        for row in reader:
            project_id = row.get('ID', '')
            kml_urls_str = row.get('KML URLs', '')

            if not kml_urls_str:
                continue

            # Parse multiple URLs separated by semicolon
            kml_urls = [url.strip() for url in kml_urls_str.split(';') if url.strip()]

            for url in kml_urls:
                filename = generate_kml_filename(url)
                output_path = kml_dir / project_id / filename
                downloads.append((url, str(output_path)))

    return downloads

def get_shape_cache_dir(state: str = "") -> Path:
    """Return the cache directory for per-project shape output."""
    if state:
        return Path(f"raw/shape_cache_{state}")
    return Path("raw/shape_cache")

def build_row_signature(row: Dict[str, Any]) -> str:
    """Create a stable signature for a CSV row."""
    normalized_row = {key: row.get(key, "") for key in sorted(row.keys())}
    payload = json.dumps(normalized_row, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()

def get_project_cache_path(cache_dir: Path, project_id: str) -> Path:
    """Return the cache file path for a project."""
    cache_key = project_id or "unknown-project"
    return cache_dir / f"{cache_key}.json"

def collect_kml_input_metadata(kml_paths: List[Path]) -> List[Dict[str, Any]]:
    """Capture enough metadata to know when cached feature output is stale."""
    metadata = []
    for kml_path in sorted(kml_paths):
        stat = kml_path.stat()
        metadata.append({
            "path": str(kml_path),
            "size": stat.st_size,
            "mtime_ns": stat.st_mtime_ns,
        })
    return metadata

def load_cached_project_features(
    cache_path: Path,
    row_signature: str,
    kml_metadata: List[Dict[str, Any]],
) -> Optional[List[Dict[str, Any]]]:
    """Load cached features if the CSV row and KML inputs are unchanged."""
    if not cache_path.exists():
        return None

    try:
        with open(cache_path, "r", encoding="utf-8") as cache_file:
            cache_payload = json.load(cache_file)
    except (OSError, json.JSONDecodeError):
        return None

    if cache_payload.get("cache_version") != SHAPE_CACHE_VERSION:
        return None

    if cache_payload.get("row_signature") != row_signature:
        return None

    if cache_payload.get("kml_inputs") != kml_metadata:
        return None

    features = cache_payload.get("features")
    if isinstance(features, list):
        return features

    return None

def write_cached_project_features(
    cache_path: Path,
    row_signature: str,
    kml_metadata: List[Dict[str, Any]],
    features: List[Dict[str, Any]],
) -> None:
    """Persist per-project feature output for resumable reruns."""
    cache_path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "cache_version": SHAPE_CACHE_VERSION,
        "row_signature": row_signature,
        "kml_inputs": kml_metadata,
        "features": features,
    }

    temp_path = cache_path.with_suffix(f"{cache_path.suffix}.tmp")
    with open(temp_path, "w", encoding="utf-8") as cache_file:
        json.dump(payload, cache_file, ensure_ascii=False)
    os.replace(temp_path, cache_path)

def batch_download_kmls(downloads: List[Tuple[str, str]]) -> bool:
    """Download KML files using the shared downloader module."""
    downloader = ParallelDownloader(
        min_batch_size=5,
        max_batch_size=15,
        min_delay=1.0,
        max_delay=3.0,
        max_concurrent=8,
        content_type='kml',
        http_method='GET'
    )

    urls_to_download = downloader.filter_existing_files(downloads)
    print(f"Skipped {downloader.skipped} existing KML files")
    print(f"Need to download {len(urls_to_download)} KML files")

    if urls_to_download:
        asyncio.run(downloader.process_downloads(urls_to_download))

    print("\nKML Download Summary:")
    print(f"  Downloaded: {downloader.downloaded}")
    print(f"  Skipped (existing): {downloader.skipped}")
    print(f"  Failed: {downloader.failed}")

    return downloader.failed == 0

def parse_kml_coordinates(coord_string: str) -> List[List[float]]:
    """Parse KML coordinate string into list of [lon, lat] pairs
    
    KML coordinates are formatted as: lon1,lat1,alt1 lon2,lat2,alt2 lon3,lat3,alt3
    where coordinate triplets are separated by whitespace, and values within
    a triplet are separated by commas.
    """
    coordinates = []
    
    # Clean up the coordinate string
    coord_string = coord_string.strip()
    
    # Split by whitespace to get individual coordinate triplets
    coord_triplets = coord_string.split()
    
    for triplet in coord_triplets:
        # Split each triplet by commas to get lon, lat, and optionally altitude
        parts = triplet.split(',')
        
        try:
            if len(parts) >= 2:
                lon = float(parts[0])
                lat = float(parts[1])
                # Ignore altitude (parts[2]) if present
                coordinates.append([lon, lat])
        except (ValueError, IndexError):
            # Skip invalid coordinate triplets
            continue
            
    return coordinates

def kml_to_geojson_feature(kml_path: Path, csv_row: Dict[str, Any]) -> List[Dict[str, Any]]:
    """Convert KML file to GeoJSON features with CSV attributes"""
    features = []
    
    try:
        with open(kml_path, 'r', encoding='utf-8') as f:
            content = f.read()
    except UnicodeDecodeError:
        try:
            with open(kml_path, 'r', encoding='latin-1') as f:
                content = f.read()
        except:
            print(f"Could not read {kml_path}")
            return features
    
    try:
        root = ET.fromstring(content)
        
        # Handle namespace
        ns = {'kml': 'http://www.opengis.net/kml/2.2'}
        if root.tag.startswith('{'):
            ns_uri = root.tag.split('}')[0][1:]
            ns = {'kml': ns_uri}
        
        # Find all placemarks
        placemarks = root.findall('.//kml:Placemark', ns)
        if not placemarks:
            placemarks = root.findall('.//Placemark')
        
        for placemark in placemarks:
            feature = {
                "type": "Feature",
                "properties": dict(csv_row),  # Copy all CSV attributes
                "geometry": None
            }
            
            # Add placemark name if available
            name_elem = placemark.find('.//kml:name', ns)
            if name_elem is None:
                name_elem = placemark.find('.//name')
            if name_elem is not None and name_elem.text:
                feature["properties"]["kml_name"] = name_elem.text
            
            # Add placemark description if available
            desc_elem = placemark.find('.//kml:description', ns)
            if desc_elem is None:
                desc_elem = placemark.find('.//description')
            if desc_elem is not None and desc_elem.text:
                feature["properties"]["kml_description"] = desc_elem.text
            
            # Handle different geometry types
            
            # Point
            point = placemark.find('.//kml:Point/kml:coordinates', ns)
            if point is None:
                point = placemark.find('.//Point/coordinates')
            if point is not None and point.text:
                coords = parse_kml_coordinates(point.text)
                if coords:
                    feature["geometry"] = {
                        "type": "Point",
                        "coordinates": coords[0]
                    }
            
            # LineString
            linestring = placemark.find('.//kml:LineString/kml:coordinates', ns)
            if linestring is None:
                linestring = placemark.find('.//LineString/coordinates')
            if linestring is not None and linestring.text:
                coords = parse_kml_coordinates(linestring.text)
                if coords:
                    # Validate LineString has at least 2 points
                    if len(coords) >= 2:
                        feature["geometry"] = {
                            "type": "LineString",
                            "coordinates": coords
                        }
                    elif len(coords) == 1:
                        # Convert single-point LineString to Point
                        feature["geometry"] = {
                            "type": "Point",
                            "coordinates": coords[0]
                        }
            
            # Polygon
            polygon = placemark.find('.//kml:Polygon', ns)
            if polygon is None:
                polygon = placemark.find('.//Polygon')
            if polygon is not None:
                # Outer boundary
                outer_coords = polygon.find('.//kml:outerBoundaryIs/kml:LinearRing/kml:coordinates', ns)
                if outer_coords is None:
                    outer_coords = polygon.find('.//outerBoundaryIs/LinearRing/coordinates')
                
                if outer_coords is not None and outer_coords.text:
                    coords = parse_kml_coordinates(outer_coords.text)
                    if coords:
                        # Validate polygon has at least 3 unique points (4 including closure)
                        if len(coords) >= 3:
                            # Close the polygon if not already closed
                            if coords[0] != coords[-1]:
                                coords.append(coords[0])
                            
                            # Final validation - must have at least 4 points after closing
                            if len(coords) >= 4:
                                feature["geometry"] = {
                                    "type": "Polygon",
                                    "coordinates": [coords]
                                }
                                
                                # Handle inner boundaries (holes)
                                inner_boundaries = polygon.findall('.//kml:innerBoundaryIs/kml:LinearRing/kml:coordinates', ns)
                                if not inner_boundaries:
                                    inner_boundaries = polygon.findall('.//innerBoundaryIs/LinearRing/coordinates')
                                
                                for inner in inner_boundaries:
                                    if inner.text:
                                        inner_coords = parse_kml_coordinates(inner.text)
                                        if inner_coords and len(inner_coords) >= 3:
                                            if inner_coords[0] != inner_coords[-1]:
                                                inner_coords.append(inner_coords[0])
                                            if len(inner_coords) >= 4:
                                                feature["geometry"]["coordinates"].append(inner_coords)
            
            # Only add features with valid geometry
            if feature["geometry"] is not None:
                features.append(feature)
        
    except ET.ParseError as e:
        print(f"Error parsing KML {kml_path}: {e}")
    except Exception as e:
        print(f"Unexpected error processing KML {kml_path}: {e}")
    
    return features

def process_csv_to_geojsonl(csv_path: str, output_path: str = "geojsonoutput.geojsonl", state: str = ""):
    """Process CSV and create a GeoJSONL file using resumable per-project caches."""
    
    # Use state-specific KML directory if state is provided
    if state:
        kml_dir = Path(f"kml/{state}")
    else:
        kml_dir = Path("kml")
    cache_dir = get_shape_cache_dir(state)
    cache_dir.mkdir(parents=True, exist_ok=True)
    
    print("Generating KML URL list for batch downloading...")
    downloads = collect_kml_downloads(csv_path, kml_dir)
    print(f"Generated {len(downloads)} KML URLs")
    
    if not downloads:
        print("No KML URLs found in CSV file")
        return
    
    # Batch download KML files using the shared downloader logic
    print("\nStarting batch download of KML files...")
    download_success = batch_download_kmls(downloads)
    
    if not download_success:
        print("Warning: Batch download encountered errors. Continuing with available files...")
    
    # Process downloaded KML files into GeoJSON
    print("\nProcessing KML files to GeoJSONL...")
    processed_count = 0
    reused_cache_count = 0
    generated_count = 0
    feature_count = 0

    output_dir = os.path.dirname(output_path) or "."
    os.makedirs(output_dir, exist_ok=True)
    temp_fd, temp_output_path = tempfile.mkstemp(
        prefix=os.path.basename(output_path),
        suffix=".tmp",
        dir=output_dir,
    )
    os.close(temp_fd)
    
    try:
        with open(temp_output_path, "w", encoding="utf-8") as output_file:
            # Read CSV file again to process each row
            with open(csv_path, 'r', encoding='utf-8') as csvfile:
                reader = csv.DictReader(csvfile)
                rows = list(reader)
                total_projects = len(rows)
                
                for row_idx, row in enumerate(rows, 1):
                    proposal_id = row.get('Proposal Number', '')
                    project_id = row.get('ID', '')
                    kml_urls_str = row.get('KML URLs', '')
                    
                    if not kml_urls_str:
                        continue
                        
                    # Parse multiple URLs separated by semicolon
                    kml_urls = [url.strip() for url in kml_urls_str.split(';') if url.strip()]
                    
                    if not kml_urls:
                        continue
                    
                    print(f"Processing {proposal_id} (ID: {project_id}) ({row_idx}/{total_projects}) with {len(kml_urls)} KML file(s)")

                    existing_kml_paths: List[Path] = []
                    for url in kml_urls:
                        filename = generate_kml_filename(url)
                        kml_path = kml_dir / project_id / filename

                        if kml_path.exists():
                            existing_kml_paths.append(kml_path)
                        else:
                            print(f"  Warning: KML file not found: {kml_path}")

                    if not existing_kml_paths:
                        continue

                    row_signature = build_row_signature(row)
                    kml_metadata = collect_kml_input_metadata(existing_kml_paths)
                    cache_path = get_project_cache_path(cache_dir, project_id)
                    project_features = load_cached_project_features(cache_path, row_signature, kml_metadata)

                    if project_features is None:
                        project_features = []
                        for kml_path in existing_kml_paths:
                            project_features.extend(kml_to_geojson_feature(kml_path, row))
                        write_cached_project_features(cache_path, row_signature, kml_metadata, project_features)
                        generated_count += 1
                    else:
                        reused_cache_count += 1

                    if project_features:
                        processed_count += 1
                        for feature in project_features:
                            output_file.write(json.dumps(feature, ensure_ascii=False))
                            output_file.write("\n")
                            feature_count += 1

        os.replace(temp_output_path, output_path)
    finally:
        if os.path.exists(temp_output_path):
            os.remove(temp_output_path)

    print(f"Processed {processed_count} projects with valid geometry")
    print(f"Shape cache summary: generated={generated_count} reused_cache={reused_cache_count}")
    print(f"Created {output_path} with {feature_count} features")

def main():
    """Main entry point"""
    if len(sys.argv) < 2:
        print("Usage: python 4_make_shape.py <STATE> [output_file]")
        print("Example: python 4_make_shape.py 30")
        print("This will read csv/Projects_30.csv and output to geojson/Projects_30.geojsonl")
        sys.exit(1)
    
    state = sys.argv[1]
    
    # Generate input and output paths based on state
    csv_path = f"csv/Projects_{state}.csv"
    
    if len(sys.argv) > 2:
        output_path = sys.argv[2]
    else:
        # Create geojson directory if it doesn't exist
        os.makedirs("geojson", exist_ok=True)
        output_path = f"geojson/Projects_{state}.geojsonl"
    
    if not os.path.exists(csv_path):
        print(f"Error: CSV file {csv_path} not found")
        sys.exit(1)
    
    print(f"Processing state {state}")
    print(f"Input: {csv_path}")
    print(f"Output: {output_path}")
    print(f"KML files will be saved to: kml/{state}/$ID/")
    print()
    
    process_csv_to_geojsonl(csv_path, output_path, state)

if __name__ == "__main__":
    main()
