import os
import json
import polars as pl
import sys
import tempfile
import xml.etree.ElementTree as ET
from typing import Dict, Any, Union, Optional

PARSE_CACHE_VERSION = 1

def get_directory_path(state: str = None) -> str:
    """Get the appropriate directory path based on state parameter."""
    if state:
        return f"raw/caf_{state.lower()}"
    return "raw/caf"

def get_cache_directory_path(state: str = None) -> str:
    """Get the cache directory path for parsed CAF payloads."""
    if state:
        return f"raw/parse_cache_{state.lower()}"
    return "raw/parse_cache"

# Get state parameter from command line arguments
state_param = sys.argv[1] if len(sys.argv) > 1 else None
directory = get_directory_path(state_param)

print(f"Processing data from directory: {directory}")

if not os.path.exists(directory):
    print(f"Error: Directory {directory} does not exist. Please run initialize.sh and fetch.sh first.")
    sys.exit(1)

def recursive_find_json(directory: str) -> list[str]:
    """Recursively finds JSON files in the given directory."""
    return [os.path.join(root, file) for root, _, files in os.walk(directory) for file in files if file.endswith('.json')]

def get_cache_file_path(file_path: str, source_directory: str, cache_directory: str) -> str:
    """Map a source CAF file to its cache entry path."""
    relative_path = os.path.relpath(file_path, source_directory)
    return os.path.join(cache_directory, relative_path)

def load_cached_parse_result(file_path: str, cache_file_path: str) -> Optional[Dict[str, Any]]:
    """Load a cached parse result when the source file has not changed."""
    if not os.path.exists(cache_file_path):
        return None

    try:
        source_stat = os.stat(file_path)
        with open(cache_file_path, 'r', encoding='utf-8') as cache_file:
            cached_data = json.load(cache_file)

        if cached_data.get('cache_version') != PARSE_CACHE_VERSION:
            return None

        if cached_data.get('source_size') != source_stat.st_size:
            return None

        if cached_data.get('source_mtime_ns') != source_stat.st_mtime_ns:
            return None

        parsed = cached_data.get('parsed')
        if isinstance(parsed, dict):
            return parsed
    except (json.JSONDecodeError, OSError, TypeError):
        return None

    return None

def write_cached_parse_result(file_path: str, cache_file_path: str, parsed_result: Dict[str, Any]) -> None:
    """Persist a parsed result for reuse on later runs."""
    source_stat = os.stat(file_path)
    os.makedirs(os.path.dirname(cache_file_path), exist_ok=True)

    payload = {
        'cache_version': PARSE_CACHE_VERSION,
        'source_size': source_stat.st_size,
        'source_mtime_ns': source_stat.st_mtime_ns,
        'parsed': parsed_result,
    }

    temp_file_path = f"{cache_file_path}.tmp"
    with open(temp_file_path, 'w', encoding='utf-8') as cache_file:
        json.dump(payload, cache_file, ensure_ascii=False)

    os.replace(temp_file_path, cache_file_path)

def parse_xml_content(xml_string: str) -> Dict[str, Any]:
    """Parse XML content and extract fields."""
    try:
        root = ET.fromstring(xml_string)
        result = {}
        
        # Extract direct XML elements
        xml_fields = {
            'nameOfUserAgency': 'Organization Name',
            'state': 'State', 
            'proposalNo': 'Proposal Number',
            'projectName': 'Project Name',
            'category': 'Project Category (Code)',
            'proposalStatus': 'Proposal Status',
            'app_updated_on': 'Application Updated On'
        }
        
        for xml_tag, field_name in xml_fields.items():
            element = root.find(xml_tag)
            if element is not None and element.text:
                result[field_name] = element.text.strip()
        
        # Parse other_property JSON if present
        other_property = root.find('other_property')
        if other_property is not None and other_property.text:
            try:
                properties = json.loads(other_property.text)
                for prop in properties:
                    if prop.get('label') == 'Activity':
                        result['Project Category'] = prop.get('value', '')
                    elif prop.get('label') == 'Sector':
                        result['Sector'] = prop.get('value', '')
            except json.JSONDecodeError:
                pass
        
        return result
    except ET.ParseError:
        return {}

def parse_json(file_path: str) -> Dict[str, Any]:
    """Parses a JSON file and extracts specified keys."""
    try:
        with open(file_path, 'r') as f:
            content = f.read().strip()
        
        # Try to parse as JSON first
        try:
            data = json.loads(content)
            result = extract_values(data)
        except json.JSONDecodeError:
            # If JSON parsing fails, try XML parsing
            result = parse_xml_content(content)
        
        proposal_id = file_path.split('/')[-1].strip('.json')
        result['proposal_url'] = f"https://parivesh.nic.in/newupgrade/#/report/ec?proposalId={proposal_id}"
        
        return result
    
    except Exception as e:
        print(f"Error processing {file_path}: {str(e)}")
    
    return {}

def safe_get(d: Union[Dict, list], *keys) -> Any:
    """Safely navigate nested dictionaries and lists."""
    for key in keys:
        if isinstance(d, dict):
            if key in d:
                d = d[key]
            else:
                return None
        elif isinstance(d, list):
            if isinstance(key, int) and 0 <= key < len(d):
                d = d[key]
            else:
                return None
        else:
            return None
    return d

def extract_kml_urls(data: Dict[str, Any]) -> list[str]:
    """Extract KML URLs from the data"""
    kml_urls = []
    seen_urls = set()  # To avoid duplicates
    
    def extract_kml_from_object(kml_obj: Dict[str, Any]) -> None:
        """Helper function to extract KML URL from a KML object"""
        if isinstance(kml_obj, dict) and 'document_name' in kml_obj:
            document_name = kml_obj['document_name']
            if document_name and document_name.endswith('.kml'):
                # Extract required fields for the URL
                doc_mapping_id = kml_obj.get('document_mapping_id')
                ref_id = kml_obj.get('ref_id')
                ref_type = kml_obj.get('type')
                uuid = kml_obj.get('uuid')
                version = kml_obj.get('version')
                
                # Construct the KML URL with the correct format
                if all([doc_mapping_id, ref_id, ref_type, uuid, version]):
                    kml_url = f"https://parivesh.nic.in/dms/okm/downloadDocument?docTypemappingId={doc_mapping_id}&refId={ref_id}&refType={ref_type}&uuid={uuid}&version={version}"
                    if kml_url not in seen_urls:
                        kml_urls.append(kml_url)
                        seen_urls.add(kml_url)
    
    # 1. Extract from cafKML array in commonFormDetails (all items)
    common_form_details = safe_get(data, 'data', 'proponentApplications', 'projectDetailDto', 'commonFormDetails')
    if common_form_details and isinstance(common_form_details, list):
        for form_detail in common_form_details:
            if isinstance(form_detail, dict):
                caf_kml_list = form_detail.get('cafKML')
                if caf_kml_list and isinstance(caf_kml_list, list):
                    for caf_kml_item in caf_kml_list:
                        if isinstance(caf_kml_item, dict) and 'caf_kml' in caf_kml_item:
                            extract_kml_from_object(caf_kml_item['caf_kml'])
    
    # 2. Extract from commonFormDetail (single item) in clearence
    common_form_detail = safe_get(data, 'data', 'clearence', 'commonFormDetail')
    if isinstance(common_form_detail, dict):
        caf_kml_list = common_form_detail.get('cafKML')
        if caf_kml_list and isinstance(caf_kml_list, list):
            for caf_kml_item in caf_kml_list:
                if isinstance(caf_kml_item, dict) and 'caf_kml' in caf_kml_item:
                    extract_kml_from_object(caf_kml_item['caf_kml'])
    
    # 3. Extract from forestClearancePatchKmls
    patch_kmls = safe_get(data, 'data', 'clearence', 'forestClearancePatchKmls')
    if patch_kmls and isinstance(patch_kmls, list):
        for patch_kml_item in patch_kmls:
            if isinstance(patch_kml_item, dict) and 'patch_kml' in patch_kml_item:
                extract_kml_from_object(patch_kml_item['patch_kml'])
    
    # 4. Extract from forestClearanceProposedDiversions
    proposed_diversions = safe_get(data, 'data', 'clearence', 'forestClearanceProposedDiversions')
    if proposed_diversions and isinstance(proposed_diversions, list):
        for diversion in proposed_diversions:
            if isinstance(diversion, dict) and 'kml' in diversion:
                extract_kml_from_object(diversion['kml'])
    
    return kml_urls

def extract_values(data: Dict[str, Any]) -> Dict[str, Any]:
    """Extracts available values from the data"""
    results = {}
    
    fields_to_extract = {
        'ID': ('data', 'proponentApplications', 'id'),
        'Category': ('data', 'proponentApplications', 'applications', 'category'),
        'Description': ('data', 'proponentApplications', 'applications', 'description'),


        'Proposal Number': ('data', 'proponentApplications', 'proposal_no'),
        'Application Date': ('data', 'proponentApplications', 'created_on'),
        'Project Name': ('data', 'proponentApplications', 'projectDetailDto', 'projectName'),
        'Project Description': ('data', 'proponentApplications', 'projectDetailDto', 'commonFormDetails', 0, 'project_description'),
        'Total Cost (Lakhs)': ('data', 'proponentApplications', 'projectDetailDto', 'commonFormDetails', 0, 'cafProjectActivityCost', 'total_cost'),
        'Employment (Construction)': ('data', 'proponentApplications', 'projectDetailDto', 'commonFormDetails', 0, 'cafProjectActivityCost', 'cp_total_employment'),
        'Employment (Operational)': ('data', 'proponentApplications', 'projectDetailDto', 'commonFormDetails', 0, 'cafProjectActivityCost', 'op_existing_total_employment'),
        'Project Land Requirement (Hectares)': ('data', 'proponentApplications', 'projectDetailDto', 'commonFormDetails', 0, 'cafLocationOfKml', 'existing_total_land'),
        'Organization Name': ('data', 'proponentApplications', 'projectDetailDto', 'commonFormDetails', 0, 'organization_name'),
        'Project Category (Code)': ('data', 'clearence', 'project_category'),
        'Project Category': ('data', 'clearence', 'environmentClearanceProjectActivityDetails', 0, 'activities', 'name'),
        
        # Geographic information fields
        
        'Plot Number': ('data', 'proponentApplications', 'projectDetailDto', 'commonFormDetails', 0, 'cafKML', 0, 'cafKMLPlots', 0, 'plot_no'),
        'Village': ('data', 'proponentApplications', 'projectDetailDto', 'commonFormDetails', 0, 'cafKML', 0, 'cafKMLPlots', 0, 'village'),
        'Sub District': ('data', 'proponentApplications', 'projectDetailDto', 'commonFormDetails', 0, 'cafKML', 0, 'cafKMLPlots', 0, 'sub_District'),
        'District': ('data', 'proponentApplications', 'projectDetailDto', 'commonFormDetails', 0, 'cafKML', 0, 'cafKMLPlots', 0, 'district'),
        'State': ('data', 'proponentApplications', 'state'),
        'Village Code': ('data', 'proponentApplications', 'projectDetailDto', 'commonFormDetails', 0, 'cafKML', 0, 'cafKMLPlots', 0, 'village_code'),
        
    
       'Proposal Type': ('data', 'proponentApplications', 'projectDetailDto', 'commonFormDetails', 0, 'proposal_for'),
        'MoEFCC File': ('data', 'proponentApplications', 'moefccFileNumber'),
        'State File': ('data', 'proponentApplications', 'stateFileNumber'),
        'Plot Nos': ('data', 'proponentApplications', 'projectDetailDto', 'commonFormDetails', 0, 'cafKML', 0, 'cafKMLPlots', 0, 'plot_no'),
        'Shape of Project': ('data', 'proponentApplications', 'projectDetailDto', 'commonFormDetails', 0, 'cafLocationOfKml', 'shape_of_project'),
        'Existing Non-Forest Land': ('data', 'proponentApplications', 'projectDetailDto', 'commonFormDetails', 0, 'cafLocationOfKml', 'existing_non_forest_land'),
        'Existing Forest Land': ('data', 'proponentApplications', 'projectDetailDto', 'commonFormDetails', 0, 'cafLocationOfKml', 'existing_forest_land'),
        'Existing Total Land': ('data', 'proponentApplications', 'projectDetailDto', 'commonFormDetails', 0, 'cafLocationOfKml', 'existing_total_land'),
        'Additional Non-Forest Land': ('data', 'proponentApplications', 'projectDetailDto', 'commonFormDetails', 0, 'cafLocationOfKml', 'additional_non_forest_land'),
        'Additional Forest Land': ('data', 'proponentApplications', 'projectDetailDto', 'commonFormDetails', 0, 'cafLocationOfKml', 'additional_forest_land'),
        'Additional Total Land': ('data', 'proponentApplications', 'projectDetailDto', 'commonFormDetails', 0, 'cafLocationOfKml', 'additional_total_land'),
        'Existing Cost': ('data', 'proponentApplications', 'projectDetailDto', 'commonFormDetails', 0, 'cafProjectActivityCost', 'total_existing_cost'),
        'Expansion Cost': ('data', 'proponentApplications', 'projectDetailDto', 'commonFormDetails', 0, 'cafProjectActivityCost', 'total_expension_cost'),
        'Villages Affected': ('data', 'proponentApplications', 'projectDetailDto', 'commonFormDetails', 0, 'cafOthers', 'no_of_villages'),
        'Project Displaced Families': ('data', 'proponentApplications', 'projectDetailDto', 'commonFormDetails', 0, 'cafOthers', 'no_of_project_displaced_families'),
        'Project Affected Families': ('data', 'proponentApplications', 'projectDetailDto', 'commonFormDetails', 0, 'cafOthers', 'no_of_project_affected_families'),
        'Alternative Site Examined': ('data', 'proponentApplications', 'projectDetailDto', 'commonFormDetails', 0, 'cafOthers', 'is_alternative_sites_examined'),
        'Alternative Site Description': ('data', 'proponentApplications', 'projectDetailDto', 'commonFormDetails', 0, 'cafOthers', 'alternative_sites_description'),
        'Government Restriction': ('data', 'proponentApplications', 'projectDetailDto', 'commonFormDetails', 0, 'cafOthers', 'is_any_govt_restriction'),
        'Litigation Pending': ('data', 'proponentApplications', 'projectDetailDto', 'commonFormDetails', 0, 'cafOthers', 'is_any_litigation_pending'),
        'Violation Involved': ('data', 'proponentApplications', 'projectDetailDto', 'commonFormDetails', 0, 'cafOthers', 'is_any_violayion_involved'),
        'Last Visible Status': ('data', 'proponentApplications', 'last_visible_status'),
        'Last Submission Date': ('data', 'proponentApplications', 'last_submission_date'),
        'Grant Date': ('data', 'proponentApplications', 'grant_date'),
        'Project Exemption Reason': ('data', 'clearence', 'project_exempted_reason'),
        'EC Consultant': ('data', 'clearence', 'ecConsultant', 'consultant_name'),
        
        # Compensatory Afforestation fields
        'Compensatory Afforestation Type': ('data', 'clearence', 'fcAforestationDetails', 'comp_afforestation_type'),
        'Is Applicable Compensatory Afforestation': ('data', 'clearence', 'fcAforestationDetails', 'is_applicable_compensatory_afforestation'),
        
        # Mining Proposal fields
        'Mining Date of Issue': ('data', 'clearence', 'forestClearanceMiningProposals', 'date_of_issue'),
        'Mining Date of Validity': ('data', 'clearence', 'forestClearanceMiningProposals', 'date_of_validity'),
        'Mining Lease Period': ('data', 'clearence', 'forestClearanceMiningProposals', 'lease_period'),
        'Mining Date of Expiry': ('data', 'clearence', 'forestClearanceMiningProposals', 'date_of_expiry'),
        'Mining Lease Area': ('data', 'clearence', 'forestClearanceMiningProposals', 'lease_area'),
        'Mining Production Capacity': ('data', 'clearence', 'forestClearanceMiningProposals', 'production_capacity'),
        'Mining Other Info': ('data', 'clearence', 'forestClearanceMiningProposals', 'other_info'),
        'Mining Status of Approval': ('data', 'clearence', 'forestClearanceMiningProposals', 'status_of_approval'),
        'Mining Approved Life of Mine': ('data', 'clearence', 'forestClearanceMiningProposals', 'approved_life_of_mine'),
        'Mining Approving Authority Name': ('data', 'clearence', 'forestClearanceMiningProposals', 'approving_authority_name'),
        'Mining Life of Mine Other Info': ('data', 'clearence', 'forestClearanceMiningProposals', 'life_of_mine_other_info'),
        'Mining Type of Mining': ('data', 'clearence', 'forestClearanceMiningProposals', 'type_of_mining'),
        'Mining Method of Mining': ('data', 'clearence', 'forestClearanceMiningProposals', 'method_of_mining'),
        'Mining Type of Mining Other Info': ('data', 'clearence', 'forestClearanceMiningProposals', 'type_of_mining_other_info'),
        'Mining Blasting Other Info': ('data', 'clearence', 'forestClearanceMiningProposals', 'blasting_other_info'),
        'Mining Total Quarry Area': ('data', 'clearence', 'forestClearanceMiningProposals', 'total_quarry_area'),
        'Mining Quarry Other Info': ('data', 'clearence', 'forestClearanceMiningProposals', 'quarry_other_info'),
        'Mining Transportation Mode From Pithead': ('data', 'clearence', 'forestClearanceMiningProposals', 'transportation_mode_from_pithead'),
        'Mining Transportation Mode From Loading': ('data', 'clearence', 'forestClearanceMiningProposals', 'transportation_mode_from_loading'),
        'Mining Transportation Mode Other Info': ('data', 'clearence', 'forestClearanceMiningProposals', 'transportation_mode_other_info'),
        'Mining Plantation Area': ('data', 'clearence', 'forestClearanceMiningProposals', 'plantation_area'),
        'Mining Water Body': ('data', 'clearence', 'forestClearanceMiningProposals', 'water_body'),
        'Mining Public Use': ('data', 'clearence', 'forestClearanceMiningProposals', 'public_use'),
        'Mining Other Use': ('data', 'clearence', 'forestClearanceMiningProposals', 'other_use'),
        
        # Organization and Applicant fields from commonFormDetail
        'Organization Street': ('data', 'clearence', 'commonFormDetail', 'organization_street'),
        'Organization City': ('data', 'clearence', 'commonFormDetail', 'organization_city'),
        'Organization State': ('data', 'clearence', 'commonFormDetail', 'organization_state'),
        'Organization Legal Status': ('data', 'clearence', 'commonFormDetail', 'organization_legal_status'),
        'Applicant Designation': ('data', 'clearence', 'commonFormDetail', 'applicant_designation'),
        'Applicant City': ('data', 'clearence', 'commonFormDetail', 'applicant_city'),
        'Applicant State': ('data', 'clearence', 'commonFormDetail', 'applicant_state'),
    }

    for field, keys in fields_to_extract.items():
        value = safe_get(data, *keys)
        if value is not None:
            results[field] = value

    # Extract KML URLs
    kml_urls = extract_kml_urls(data)
    if kml_urls:
        results['KML URLs'] = ';'.join(kml_urls)  # Join multiple URLs with semicolon

    # EIA Report PDF URL
    eia = safe_get(data, 'data', 'proponentApplications', 'ecEnclosures', 'eia_final_copy')
    if eia and isinstance(eia, dict):
        doc_id = eia.get('document_mapping_id')
        ref_id = eia.get('ref_id')
        ref_type = eia.get('type')
        uuid = eia.get('uuid')
        version = eia.get('version')
        if all([doc_id, ref_id, ref_type, uuid, version]):
            eia_url = f"https://parivesh.nic.in/dms/okm/downloadDocument?docTypemappingId={doc_id}&refId={ref_id}&refType={ref_type}&uuid={uuid}&version={version}"
            results['EIA Report PDF'] = eia_url

    # Cost Benefit Report PDF URL
    cost_benefit_report = safe_get(data, 'data', 'clearence', 'fcOthersDetail', 'cost_benefit_report')
    if cost_benefit_report and isinstance(cost_benefit_report, dict):
        doc_id = cost_benefit_report.get('document_mapping_id')
        ref_id = cost_benefit_report.get('ref_id')
        ref_type = cost_benefit_report.get('type')
        uuid = cost_benefit_report.get('uuid')
        version = cost_benefit_report.get('version')
        if all([doc_id, ref_id, ref_type, uuid, version]):
            cost_benefit_url = f"https://parivesh.nic.in/dms/okm/downloadDocument?docTypemappingId={doc_id}&refId={ref_id}&refType={ref_type}&uuid={uuid}&version={version}"
            results['Cost Benefit Report PDF'] = cost_benefit_url

    # Mining array fields - estimated reserves (concatenated)
    mining_proposal = safe_get(data, 'data', 'clearence', 'forestClearanceMiningProposals')
    if mining_proposal and isinstance(mining_proposal, dict):
        # Estimated Reserve Minerals
        estimated_reserves = mining_proposal.get('estimatedReserveMinerals', [])
        if estimated_reserves and isinstance(estimated_reserves, list):
            names = [str(reserve.get('estimated_reserves_name', '')) for reserve in estimated_reserves if reserve.get('estimated_reserves_name')]
            fl_values = [str(reserve.get('estimated_reserves_fl', '')) for reserve in estimated_reserves if reserve.get('estimated_reserves_fl') is not None]
            nfl_values = [str(reserve.get('estimated_reserves_nfl', '')) for reserve in estimated_reserves if reserve.get('estimated_reserves_nfl') is not None]
            
            if names:
                results['Mining Estimated Reserve Names'] = ','.join(names)
            if fl_values:
                results['Mining Estimated Reserve FL'] = ','.join(fl_values)
            if nfl_values:
                results['Mining Estimated Reserve NFL'] = ','.join(nfl_values)
        
        # Mining Mineral Reserves
        mineral_reserves = mining_proposal.get('miningMineralReserves', [])
        if mineral_reserves and isinstance(mineral_reserves, list):
            proved_reserves = [str(reserve.get('proved_reserves', '')) for reserve in mineral_reserves if reserve.get('proved_reserves') is not None]
            indicated_reserves = [str(reserve.get('indicated_reserves', '')) for reserve in mineral_reserves if reserve.get('indicated_reserves') is not None]
            inferred_reserves = [str(reserve.get('inferred_reserves', '')) for reserve in mineral_reserves if reserve.get('inferred_reserves') is not None]
            mineable_reserves = [str(reserve.get('mineable_reserves', '')) for reserve in mineral_reserves if reserve.get('mineable_reserves') is not None]
            
            if proved_reserves:
                results['Mining Proved Reserves'] = ','.join(proved_reserves)
            if indicated_reserves:
                results['Mining Indicated Reserves'] = ','.join(indicated_reserves)
            if inferred_reserves:
                results['Mining Inferred Reserves'] = ','.join(inferred_reserves)
            if mineable_reserves:
                results['Mining Mineable Reserves'] = ','.join(mineable_reserves)
        
        # Dumping strategy fields
        dumping_strategy = mining_proposal.get('dumping_strategy')
        if dumping_strategy and isinstance(dumping_strategy, str):
            try:
                dumping_data = json.loads(dumping_strategy)
                if isinstance(dumping_data, dict):
                    results['Mining External Dumping Remarks'] = dumping_data.get('external_dumping_remarks', '')
                    results['Mining Internal Dumping Remarks'] = dumping_data.get('internal_dumping_remarks', '')
                    results['Mining Topsoil Dumping Remarks'] = dumping_data.get('toposoil_dumping_remarks', '')
            except json.JSONDecodeError:
                pass

    # Forest Clearance Patch KML Details - Present Owner (concatenated)
    patch_kmls = safe_get(data, 'data', 'clearence', 'forestClearancePatchKmls')
    if patch_kmls and isinstance(patch_kmls, list):
        present_owners = []
        for patch_kml in patch_kmls:
            if isinstance(patch_kml, dict):
                patch_details = patch_kml.get('forestClearancePatchKmlDetails', [])
                if isinstance(patch_details, list):
                    for detail in patch_details:
                        if isinstance(detail, dict) and detail.get('present_owner'):
                            present_owners.append(str(detail['present_owner']))
        if present_owners:
            results['Forest Clearance Present Owners'] = ','.join(present_owners)

    return results

def main():
    json_files = recursive_find_json(directory)
    
    if not json_files:
        print(f"No JSON files found in {directory}")
        return
    
    print(f"Processing {len(json_files)} files...")
    cache_directory = get_cache_directory_path(state_param)
    os.makedirs(cache_directory, exist_ok=True)
    print(f"Using parse cache: {cache_directory}")
    
    # Use Polars to efficiently process the data
    data_list = []
    parsed_files = 0
    cached_files = 0
    failed_files = 0
    for file_path in json_files:
        cache_file_path = get_cache_file_path(file_path, directory, cache_directory)
        cached_result = load_cached_parse_result(file_path, cache_file_path)

        if cached_result is not None:
            cached_files += 1
            if cached_result:
                data_list.append(cached_result)
            continue

        result = parse_json(file_path)
        if result:  # Only add non-empty results
            data_list.append(result)
            write_cached_parse_result(file_path, cache_file_path, result)
            parsed_files += 1
        else:
            failed_files += 1
    
    if not data_list:
        print("No valid data found to process")
        return

    print(f"Parse summary: parsed={parsed_files} reused_cache={cached_files} failed={failed_files}")
    
    # Normalize data - ensure all records have all possible fields
    # This is necessary because Polars excludes columns that are missing from most records
    all_fields = set()
    for record in data_list:
        all_fields.update(record.keys())
    
    # Normalize each record to have all fields (with None for missing ones)
    normalized_data_list = []
    for record in data_list:
        normalized_record = {}
        for field in all_fields:
            normalized_record[field] = record.get(field, None)
        normalized_data_list.append(normalized_record)
    
    # Create DataFrame with increased schema inference to handle mixed types
    df = pl.DataFrame(normalized_data_list, infer_schema_length=len(normalized_data_list))
    
    # Filter rows to keep only those with a valid 'Proposal Number'
    if 'Proposal Number' in df.columns:
        df = df.filter(pl.col('Proposal Number').is_not_null())
    
    # Replace newlines with semicolons in string columns
    for col in df.columns:
        if df[col].dtype == pl.Utf8:
            df = df.with_columns(
                pl.col(col).str.strip_chars().alias(col)
            )
    
    # Reorder columns - put specified columns first, then remaining columns
    preferred_order = [
        'ID',
        'Project Description',
        'Proposal Type',
        'Proposal Number',
        'Application Date',
        'Grant Date',
        'Last Visible Status',
        
        'Project Land Requirement (Hectares)',
        'Total Cost (Lakhs)',
        
        'Organization Name',
        'EC Consultant',
        'Description',
        'Category',
        
        'Project Category (Code)',
        'Project Category',
    
        'Project Name',
        'State',
        'Sub District',
        'Village',

        'MoEFCC File',
        'State File',
        
        'Plot Nos',
        'Shape of Project',
        'Existing Non-Forest Land',
        'Existing Forest Land',
        'Existing Total Land',
        'Additional Non-Forest Land',
        'Additional Forest Land',
        'Additional Total Land',
        'Existing Cost',
        'Expansion Cost',
        'Villages Affected',
        'Project Displaced Families',
        'Project Affected Families',
        'Alternative Site Examined',
        'Alternative Site Description',
        'Government Restriction',
        'Litigation Pending',
        'Violation Involved',

        'Last Submission Date',
        
        'Project Exemption Reason',
        'EIA Report PDF',
        'Cost Benefit Report PDF',
        
        # Compensatory Afforestation
        'Compensatory Afforestation Type',
        'Is Applicable Compensatory Afforestation',
        
        # Mining fields
        'Mining Date of Issue',
        'Mining Date of Validity',
        'Mining Lease Period',
        'Mining Date of Expiry',
        'Mining Lease Area',
        'Mining Production Capacity',
        'Mining Other Info',
        'Mining Status of Approval',
        'Mining Estimated Reserve Names',
        'Mining Estimated Reserve FL',
        'Mining Estimated Reserve NFL',
        'Mining Proved Reserves',
        'Mining Indicated Reserves',
        'Mining Inferred Reserves',
        'Mining Mineable Reserves',
        'Mining Approved Life of Mine',
        'Mining Approving Authority Name',
        'Mining Life of Mine Other Info',
        'Mining Type of Mining',
        'Mining Method of Mining',
        'Mining Type of Mining Other Info',
        'Mining Blasting Other Info',
        'Mining External Dumping Remarks',
        'Mining Internal Dumping Remarks',
        'Mining Topsoil Dumping Remarks',
        'Mining Total Quarry Area',
        'Mining Quarry Other Info',
        'Mining Transportation Mode From Pithead',
        'Mining Transportation Mode From Loading',
        'Mining Transportation Mode Other Info',
        'Mining Plantation Area',
        'Mining Water Body',
        'Mining Public Use',
        'Mining Other Use',
        
        # Organization and Applicant details
        'Organization Street',
        'Organization City',
        'Organization State',
        'Organization Legal Status',
        'Applicant Designation',
        'Applicant City',
        'Applicant State',
        
        # Forest Clearance
        'Forest Clearance Present Owners',
    ]
    
    # Get columns that exist in the dataframe from the preferred order
    existing_preferred = [col for col in preferred_order if col in df.columns]
    
    # Get remaining columns that aren't in the preferred order
    remaining_cols = [col for col in df.columns if col not in preferred_order]
    
    # Combine to create final column order
    final_column_order = existing_preferred + remaining_cols
    
    # Reorder the dataframe columns
    df = df.select(final_column_order)
    
    # Sort by Application Date in descending order
    if 'Application Date' in df.columns:
        df = df.sort('Application Date')
    
    # Ensure the output directory exists
    os.makedirs("csv", exist_ok=True)
    
    # Create output filename based on state parameter
    if state_param:
        output_file = f"csv/Projects_{state_param.upper()}.csv"
        print(f"Processing data for state: {state_param.upper()}")
    else:
        output_file = "csv/Projects.csv"
        print("Processing data for all states")
    
    # Write to CSV atomically so interrupted runs do not leave a partial file behind.
    temp_fd, temp_output_file = tempfile.mkstemp(prefix=os.path.basename(output_file), suffix=".tmp", dir=os.path.dirname(output_file) or ".")
    os.close(temp_fd)
    try:
        df.write_csv(temp_output_file)
        os.replace(temp_output_file, output_file)
    finally:
        if os.path.exists(temp_output_file):
            os.remove(temp_output_file)

    print(f"Data saved to {output_file}")
    print(f"Total records: {len(df)}")

if __name__ == "__main__":
    main()
