#!/usr/bin/env python3

import json
import subprocess
import sys
from pathlib import Path


def run_json(cmd: list[str]) -> dict | None:
    try:
        result = subprocess.run(cmd, check=True, capture_output=True, text=True)
    except subprocess.CalledProcessError:
        return None
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return None


def get_parquet_metadata(parquet_path: Path, gpio_version: str) -> tuple[dict | None, dict | None]:
    geo_meta = run_json(
        [
            "uvx",
            "--from",
            f"geoparquet-io=={gpio_version}",
            "gpio",
            "inspect",
            "meta",
            "--json",
            str(parquet_path),
        ]
    )
    parquet_meta = run_json(
        [
            "uvx",
            "--from",
            f"geoparquet-io=={gpio_version}",
            "gpio",
            "inspect",
            "meta",
            "--parquet",
            "--json",
            str(parquet_path),
        ]
    )
    return geo_meta, parquet_meta


def extract_schema(parquet_meta: dict) -> dict:
    schema = {}
    schema_str = parquet_meta.get("schema", "")
    if not schema_str:
        return schema
    parts = schema_str.split(", ")
    for part in parts:
        if ": " not in part:
            continue
        name, type_str = part.split(": ", 1)
        if name == "schema":
            continue
        schema[name] = {"type": type_str}
    return schema


def extract_bbox(geo_meta: dict) -> list | None:
    geoparquet_meta = geo_meta.get("geoparquet_metadata", {})
    columns = geoparquet_meta.get("columns", {})
    primary = geoparquet_meta.get("primary_column", "geometry")
    if primary in columns:
        return columns[primary].get("bbox")
    for col_data in columns.values():
        if "bbox" in col_data:
            return col_data["bbox"]
    return None


def extract_geometry_types(geo_meta: dict) -> list | None:
    geoparquet_meta = geo_meta.get("geoparquet_metadata", {})
    columns = geoparquet_meta.get("columns", {})
    primary = geoparquet_meta.get("primary_column", "geometry")
    if primary in columns:
        return columns[primary].get("geometry_types")
    for col_data in columns.values():
        if "geometry_types" in col_data:
            return col_data["geometry_types"]
    return None


def main() -> int:
    if len(sys.argv) < 4:
        print(
            "Usage: create_parquet_meta.py <output_meta_path> <gpio_version> <parquet_file> [<parquet_file> ...]",
            file=sys.stderr,
        )
        return 1

    output_meta_path = Path(sys.argv[1])
    gpio_version = sys.argv[2]
    parquet_files = [Path(value) for value in sys.argv[3:]]

    meta = {"schema": {}, "geometry_types": set(), "extents": {}}

    for parquet_file in parquet_files:
        geo_meta, parquet_meta = get_parquet_metadata(parquet_file, gpio_version)
        if parquet_meta:
            for col_name, col_info in extract_schema(parquet_meta).items():
                if col_name not in meta["schema"]:
                    meta["schema"][col_name] = col_info
        if geo_meta:
            bbox = extract_bbox(geo_meta)
            if bbox:
                meta["extents"][parquet_file.name] = {
                    "minx": bbox[0],
                    "miny": bbox[1],
                    "maxx": bbox[2],
                    "maxy": bbox[3],
                }
            geometry_types = extract_geometry_types(geo_meta)
            if geometry_types:
                meta["geometry_types"].update(geometry_types)

    meta["geometry_types"] = sorted(meta["geometry_types"])
    output_meta_path.write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
    print(f"created: {output_meta_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
