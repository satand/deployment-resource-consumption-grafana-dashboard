#!/bin/bash

# =============================================================================
# Grafana Dashboard Manager
# =============================================================================
# Manages Resource Consumption Analysis dashboards in Grafana
# Dashboards: Namespace Overview, Namespace Docs, Workload Details, Workload Docs
# =============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FOLDER_TITLE="Resource Consumption Analysis"
AUTH_METHOD=""  # "apikey" or "basic"
INSECURE=false  # Skip TLS certificate verification
NAMESPACE_FILTER=""  # Optional namespace filter regex for PromQL query (default: ".*" shows all)
WORKLOAD_KINDS=""  # Optional workload kinds override (default in dashboards: ReplicaSet|ReplicationController|StatefulSet)
DATASOURCE_REGEX=""  # Optional datasource regex filter
GRAFANA_VERSION=""  # Optional Grafana version for compatibility (10 or 11)
SKIP_DOCS=false  # Skip importing documentation dashboards
DOCS_FOLDER=""  # Optional separate folder for documentation dashboards

# Dashboard files (v10 compatible - default)
DASHBOARDS_V10=(
    "grafana-dashboard.json"
    "grafana-dashboard-docs.json"
    "grafana-dashboard-workload.json"
    "grafana-dashboard-workload-docs.json"
)

# Dashboard files (v11 compatible - uses joinByField transformation)
DASHBOARDS_V11=(
    "grafana-dashboard-v11.json"
    "grafana-dashboard-docs.json"
    "grafana-dashboard-workload.json"
    "grafana-dashboard-workload-docs.json"
)

# Default to v11 dashboards
DASHBOARDS=("${DASHBOARDS_V11[@]}")

# Dashboard UIDs (must match the uid in each JSON file)
DASHBOARD_UIDS=(
    "workload-resource-analysis"
    "workload-resource-analysis-docs"
    "workload-resource-workload"
    "workload-resource-workload-docs"
)

# =============================================================================
# Helper Functions
# =============================================================================

print_header() {
    echo -e "\n${BLUE}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}\n"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS] COMMAND

Manage Resource Consumption Analysis dashboards in Grafana.

Commands:
    import      Import/update all dashboards to Grafana
    delete      Delete all dashboards from Grafana
    list        List dashboards in the target folder
    status      Check connection and folder status

Options:
    -u, --url URL           Grafana server URL (required)
                            Example: https://grafana.example.com
    
    Authentication (choose one method):
    -k, --api-key KEY       Grafana API key or Service Account token
                            Can also be set via GRAFANA_API_KEY env variable
    --user USERNAME         Grafana username (use with --password)
                            Can also be set via GRAFANA_USER env variable
    --password PASSWORD     Grafana password (use with --user)
                            Can also be set via GRAFANA_PASSWORD env variable
    
    Other options:
    -f, --folder TITLE      Folder title (default: "$FOLDER_TITLE")
    -d, --dashboard-dir DIR Directory containing dashboard JSON files
                            (default: script directory)
    -o, --overwrite         Overwrite existing dashboards (default for import)
    -n, --no-overwrite      Don't overwrite existing dashboards
    --namespace-filter REGEX Set namespace filter regex used in PromQL query
                            (e.g., "^prod-.*" or "staging|production")
                            Default is ".*" (show all namespaces)
                            Only affects namespace overview and workload dashboards
    --workload-kinds KINDS  Override workload kinds filter in imported dashboards
                            (e.g., "ReplicaSet|StatefulSet|DaemonSet")
                            Default in dashboards: ReplicaSet|ReplicationController|StatefulSet
                            Only affects namespace overview and workload dashboards
    --datasource-regex REGEX Set regex filter for Prometheus datasource variable
                            (e.g., "/.*-prod.*/" or "/prometheus-.*/")
                            Filters which datasources appear in the dropdown
    --grafana-version VER   Target Grafana version for compatibility (10 or 11)
                            Default: 11 (uses joinByField transformation)
                            Use 10 for Grafana v10.x (uses seriesToColumns transformation)
    --skip-docs             Skip importing documentation dashboards
    --docs-folder TITLE     Import documentation dashboards to a separate folder
                            (default: same as --folder)
    --insecure              Skip TLS certificate verification (for self-signed certs)
    -h, --help              Show this help message

Environment Variables:
    GRAFANA_URL             Alternative to --url
    GRAFANA_API_KEY         Alternative to --api-key
    GRAFANA_USER            Alternative to --user
    GRAFANA_PASSWORD        Alternative to --password

Examples:
    # Using API key (environment variables)
    export GRAFANA_URL="https://grafana.example.com"
    export GRAFANA_API_KEY="glsa_xxxxxxxxxxxx"
    $(basename "$0") import

    # Using username/password (environment variables)
    export GRAFANA_URL="https://grafana.example.com"
    export GRAFANA_USER="myusername"
    export GRAFANA_PASSWORD="mypassword"
    $(basename "$0") import

    # Using username/password (command line)
    $(basename "$0") -u https://grafana.example.com --user myuser --password mypass import

    # Delete all dashboards
    $(basename "$0") -u https://grafana.example.com --user myuser --password mypass delete

    # List dashboards in folder
    $(basename "$0") --user myuser --password mypass list

    # Use custom folder name
    $(basename "$0") --user myuser --password mypass -f "My Dashboards" import

    # Import with namespace filter preset (only show namespaces starting with "prod-")
    $(basename "$0") --user myuser --password mypass --namespace-filter "^prod-.*" import

    # Import with custom workload kinds (include DaemonSet)
    $(basename "$0") --user myuser --password mypass --workload-kinds "ReplicaSet|ReplicationController|StatefulSet|DaemonSet" import

    # Import dashboards compatible with Grafana v11+
    $(basename "$0") --user myuser --password mypass --grafana-version 11 import

    # Import with datasource regex filter (only show datasources matching pattern)
    $(basename "$0") --user myuser --password mypass --datasource-regex "/.*-prod.*/" import

    # Import only main dashboards (skip documentation dashboards)
    $(basename "$0") --user myuser --password mypass --skip-docs import

    # Import documentation dashboards to a separate folder
    $(basename "$0") --user myuser --password mypass --folder "Dashboards" --docs-folder "Documentation" import

EOF
    exit 1
}

check_dependencies() {
    local missing=()
    
    for cmd in curl jq; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [ ${#missing[@]} -ne 0 ]; then
        print_error "Missing required dependencies: ${missing[*]}"
        echo "Please install them and try again."
        exit 1
    fi
}

validate_config() {
    if [ -z "$GRAFANA_URL" ]; then
        print_error "Grafana URL is required. Use -u/--url or set GRAFANA_URL environment variable."
        exit 1
    fi
    
    # Remove trailing slash from URL
    GRAFANA_URL="${GRAFANA_URL%/}"
    
    # Determine authentication method
    if [ -n "$GRAFANA_API_KEY" ]; then
        AUTH_METHOD="apikey"
        print_info "Using API key authentication"
    elif [ -n "$GRAFANA_USER" ] && [ -n "$GRAFANA_PASSWORD" ]; then
        AUTH_METHOD="basic"
        print_info "Using username/password authentication"
    else
        print_error "Authentication required. Use one of:"
        echo "  - API key: -k/--api-key or GRAFANA_API_KEY env variable"
        echo "  - Basic auth: --user and --password or GRAFANA_USER/GRAFANA_PASSWORD env variables"
        exit 1
    fi
    
    # Warn about insecure mode
    if [ "$INSECURE" = true ]; then
        print_warning "TLS certificate verification is disabled (insecure mode)"
    fi
}

# =============================================================================
# Grafana API Functions
# =============================================================================

grafana_api() {
    local method="$1"
    local endpoint="$2"
    local data="$3"
    
    local curl_args=(
        -s
        -X "$method"
        -H "Content-Type: application/json"
    )
    
    # Skip TLS certificate verification if requested
    if [ "$INSECURE" = true ]; then
        curl_args+=(-k)
    fi
    
    # Add authentication based on method
    if [ "$AUTH_METHOD" = "apikey" ]; then
        curl_args+=(-H "Authorization: Bearer $GRAFANA_API_KEY")
    elif [ "$AUTH_METHOD" = "basic" ]; then
        curl_args+=(-u "${GRAFANA_USER}:${GRAFANA_PASSWORD}")
    fi
    
    if [ -n "$data" ]; then
        curl_args+=(-d "$data")
    fi
    
    curl "${curl_args[@]}" "${GRAFANA_URL}/api${endpoint}"
}

test_connection() {
    print_info "Testing connection to Grafana..."
    
    local response
    response=$(grafana_api GET "/org")
    
    if echo "$response" | jq -e '.id' > /dev/null 2>&1; then
        local org_name
        org_name=$(echo "$response" | jq -r '.name')
        print_success "Connected to Grafana organization: $org_name"
        return 0
    else
        print_error "Failed to connect to Grafana"
        echo "$response" | jq . 2>/dev/null || echo "$response"
        return 1
    fi
}

get_folder_id() {
    local folder_title="$1"
    
    local response
    response=$(grafana_api GET "/folders")
    
    echo "$response" | jq -r ".[] | select(.title == \"$folder_title\") | .id"
}

get_folder_uid() {
    local folder_title="$1"
    
    local response
    response=$(grafana_api GET "/folders")
    
    echo "$response" | jq -r ".[] | select(.title == \"$folder_title\") | .uid"
}

create_folder() {
    local folder_title="$1"
    
    print_info "Creating folder: $folder_title" >&2
    
    local response
    response=$(grafana_api POST "/folders" "{\"title\": \"$folder_title\"}")
    
    if echo "$response" | jq -e '.id' > /dev/null 2>&1; then
        local folder_uid
        folder_uid=$(echo "$response" | jq -r '.uid')
        print_success "Folder created with UID: $folder_uid" >&2
        echo "$folder_uid"
    else
        print_error "Failed to create folder" >&2
        echo "$response" | jq . >&2 2>/dev/null || echo "$response" >&2
        return 1
    fi
}

ensure_folder() {
    local folder_title="$1"
    
    local folder_uid
    folder_uid=$(get_folder_uid "$folder_title")
    
    if [ -n "$folder_uid" ]; then
        print_success "Folder exists: $folder_title (UID: $folder_uid)" >&2
        echo "$folder_uid"
    else
        create_folder "$folder_title"
    fi
}

import_dashboard() {
    local dashboard_file="$1"
    local folder_uid="$2"
    local overwrite="$3"
    local namespace_filter="$4"
    local workload_kinds="$5"
    local datasource_regex="$6"
    
    if [ ! -f "$dashboard_file" ]; then
        print_error "Dashboard file not found: $dashboard_file"
        return 1
    fi
    
    local dashboard_title
    dashboard_title=$(jq -r '.title' "$dashboard_file")
    
    print_info "Importing: $dashboard_title"
    
    # Read dashboard content
    local dashboard_content
    dashboard_content=$(cat "$dashboard_file")
    
    # Apply namespace filter if provided and dashboard has namespace_filter variable
    if [ -n "$namespace_filter" ]; then
        local has_ns_filter
        has_ns_filter=$(echo "$dashboard_content" | jq '.templating.list[] | select(.name == "namespace_filter") | .name' 2>/dev/null)
        
        if [ -n "$has_ns_filter" ]; then
            print_info "  Setting namespace_filter to: $namespace_filter"
            dashboard_content=$(echo "$dashboard_content" | jq --arg filter "$namespace_filter" '
                .templating.list = [.templating.list[] | 
                    if .name == "namespace_filter" then
                        .current.text = $filter |
                        .current.value = $filter |
                        .query = $filter |
                        .options = [{"selected": true, "text": $filter, "value": $filter}]
                    else
                        .
                    end
                ]
            ')
        fi
    fi
    
    # Apply workload kinds if provided and dashboard has workload_kinds variable
    if [ -n "$workload_kinds" ]; then
        local has_wk_var
        has_wk_var=$(echo "$dashboard_content" | jq '.templating.list[] | select(.name == "workload_kinds") | .name' 2>/dev/null)
        
        if [ -n "$has_wk_var" ]; then
            print_info "  Setting workload_kinds to: $workload_kinds"
            dashboard_content=$(echo "$dashboard_content" | jq --arg kinds "$workload_kinds" '
                .templating.list = [.templating.list[] | 
                    if .name == "workload_kinds" then
                        .current.text = $kinds |
                        .current.value = $kinds |
                        .query = $kinds |
                        .options = [{"selected": true, "text": $kinds, "value": $kinds}]
                    else
                        .
                    end
                ]
            ')
        fi
    fi
    
    # Apply datasource regex if provided and dashboard has datasource variable
    if [ -n "$datasource_regex" ]; then
        local has_ds_var
        has_ds_var=$(echo "$dashboard_content" | jq '.templating.list[] | select(.name == "datasource" and .type == "datasource") | .name' 2>/dev/null)
        
        if [ -n "$has_ds_var" ]; then
            print_info "  Setting datasource regex to: $datasource_regex"
            dashboard_content=$(echo "$dashboard_content" | jq --arg regex "$datasource_regex" '
                .templating.list = [.templating.list[] | 
                    if .name == "datasource" and .type == "datasource" then
                        .regex = $regex
                    else
                        .
                    end
                ]
            ')
        fi
    fi
    
    # Prepare the import payload
    local payload
    payload=$(jq -n \
        --argjson dashboard "$dashboard_content" \
        --arg folderUid "$folder_uid" \
        --argjson overwrite "$overwrite" \
        '{
            dashboard: $dashboard,
            folderUid: $folderUid,
            overwrite: $overwrite,
            message: "Imported via manage-dashboards.sh"
        }')
    
    # Remove the id field to allow Grafana to assign one
    payload=$(echo "$payload" | jq '.dashboard.id = null')
    
    local response
    response=$(grafana_api POST "/dashboards/db" "$payload")
    
    if echo "$response" | jq -e '.uid' > /dev/null 2>&1; then
        local uid url
        uid=$(echo "$response" | jq -r '.uid')
        url=$(echo "$response" | jq -r '.url')
        print_success "Imported: $dashboard_title"
        echo "         UID: $uid"
        echo "         URL: ${GRAFANA_URL}${url}"
        return 0
    else
        print_error "Failed to import: $dashboard_title"
        echo "$response" | jq . 2>/dev/null || echo "$response"
        return 1
    fi
}

delete_dashboard() {
    local dashboard_uid="$1"
    
    print_info "Deleting dashboard: $dashboard_uid"
    
    local response
    response=$(grafana_api DELETE "/dashboards/uid/$dashboard_uid")
    
    if echo "$response" | jq -e '.title' > /dev/null 2>&1; then
        local title
        title=$(echo "$response" | jq -r '.title')
        print_success "Deleted: $title"
        return 0
    elif echo "$response" | jq -e '.message' > /dev/null 2>&1; then
        local message
        message=$(echo "$response" | jq -r '.message')
        if [[ "$message" == *"not found"* ]]; then
            print_warning "Dashboard not found: $dashboard_uid (already deleted?)"
            return 0
        else
            print_error "Failed to delete: $message"
            return 1
        fi
    else
        print_error "Failed to delete dashboard: $dashboard_uid"
        echo "$response"
        return 1
    fi
}

list_dashboards_in_folder() {
    local folder_uid="$1"
    
    local response
    response=$(grafana_api GET "/search?folderUIDs=$folder_uid&type=dash-db")
    
    if echo "$response" | jq -e '.' > /dev/null 2>&1; then
        local count
        count=$(echo "$response" | jq 'length')
        
        if [ "$count" -eq 0 ]; then
            print_warning "No dashboards found in folder"
        else
            print_success "Found $count dashboard(s):"
            echo "$response" | jq -r '.[] | "  - \(.title) (UID: \(.uid))"'
        fi
    else
        print_error "Failed to list dashboards"
        echo "$response"
    fi
}

# =============================================================================
# Commands
# =============================================================================

cmd_status() {
    print_header "Grafana Connection Status"
    
    test_connection || exit 1
    
    echo ""
    print_info "Checking folder: $FOLDER_TITLE"
    
    local folder_uid
    folder_uid=$(get_folder_uid "$FOLDER_TITLE")
    
    if [ -n "$folder_uid" ]; then
        print_success "Folder exists (UID: $folder_uid)"
        echo ""
        list_dashboards_in_folder "$folder_uid"
    else
        print_warning "Folder does not exist"
    fi
}

cmd_list() {
    print_header "List Dashboards"
    
    test_connection || exit 1
    
    # List main folder
    local folder_uid
    folder_uid=$(get_folder_uid "$FOLDER_TITLE")
    
    if [ -z "$folder_uid" ]; then
        print_warning "Folder '$FOLDER_TITLE' not found"
    else
        print_info "Main dashboards folder: $FOLDER_TITLE"
        list_dashboards_in_folder "$folder_uid"
    fi
    
    # List docs folder if specified and different from main folder
    if [ -n "$DOCS_FOLDER" ] && [ "$DOCS_FOLDER" != "$FOLDER_TITLE" ]; then
        echo ""
        local docs_folder_uid
        docs_folder_uid=$(get_folder_uid "$DOCS_FOLDER")
        
        if [ -z "$docs_folder_uid" ]; then
            print_warning "Docs folder '$DOCS_FOLDER' not found"
        else
            print_info "Documentation dashboards folder: $DOCS_FOLDER"
            list_dashboards_in_folder "$docs_folder_uid"
        fi
    fi
}

cmd_import() {
    print_header "Import Dashboards"
    
    test_connection || exit 1
    
    # Ensure main folder exists
    local folder_uid
    folder_uid=$(ensure_folder "$FOLDER_TITLE")
    
    if [ -z "$folder_uid" ]; then
        print_error "Failed to get/create folder"
        exit 1
    fi
    
    # Ensure docs folder exists if specified
    local docs_folder_uid="$folder_uid"
    if [ -n "$DOCS_FOLDER" ] && [ "$SKIP_DOCS" != true ]; then
        docs_folder_uid=$(ensure_folder "$DOCS_FOLDER")
        if [ -z "$docs_folder_uid" ]; then
            print_error "Failed to get/create docs folder"
            exit 1
        fi
    fi
    
    echo ""
    print_info "Importing main dashboards to folder: $FOLDER_TITLE"
    if [ "$SKIP_DOCS" != true ]; then
        if [ -n "$DOCS_FOLDER" ]; then
            print_info "Importing documentation dashboards to folder: $DOCS_FOLDER"
        else
            print_info "Importing documentation dashboards to folder: $FOLDER_TITLE"
        fi
    fi
    if [ -n "$NAMESPACE_FILTER" ]; then
        print_info "Namespace filter will be set to: $NAMESPACE_FILTER"
    fi
    if [ -n "$WORKLOAD_KINDS" ]; then
        print_info "Workload kinds will be set to: $WORKLOAD_KINDS"
    fi
    if [ -n "$DATASOURCE_REGEX" ]; then
        print_info "Datasource regex will be set to: $DATASOURCE_REGEX"
    fi
    if [ "$SKIP_DOCS" = true ]; then
        print_info "Skipping documentation dashboards"
    fi
    echo ""
    
    local success=0
    local failed=0
    
    for dashboard_file in "${DASHBOARDS[@]}"; do
        local full_path="${DASHBOARD_DIR}/${dashboard_file}"
        local target_folder_uid
        
        # Determine target folder based on dashboard type
        if [[ "$dashboard_file" == *"-docs.json" ]]; then
            # Skip docs if --skip-docs is set
            if [ "$SKIP_DOCS" = true ]; then
                continue
            fi
            target_folder_uid="$docs_folder_uid"
        else
            target_folder_uid="$folder_uid"
        fi
        
        if import_dashboard "$full_path" "$target_folder_uid" "$OVERWRITE" "$NAMESPACE_FILTER" "$WORKLOAD_KINDS" "$DATASOURCE_REGEX"; then
            ((success++))
        else
            ((failed++))
        fi
        echo ""
    done
    
    print_header "Import Summary"
    print_success "Successfully imported: $success"
    if [ $failed -gt 0 ]; then
        print_error "Failed: $failed"
        exit 1
    fi
}

cmd_delete() {
    print_header "Delete Dashboards"
    
    test_connection || exit 1
    
    # Build list of UIDs to delete based on --skip-docs
    local uids_to_delete=()
    local main_uids=("workload-resource-analysis" "workload-resource-workload")
    local docs_uids=("workload-resource-analysis-docs" "workload-resource-workload-docs")
    
    # Always include main dashboards
    uids_to_delete+=("${main_uids[@]}")
    
    # Include docs unless --skip-docs is set
    if [ "$SKIP_DOCS" != true ]; then
        uids_to_delete+=("${docs_uids[@]}")
    fi
    
    echo ""
    print_warning "This will delete the following dashboards:"
    echo ""
    print_info "Main dashboards (folder: $FOLDER_TITLE):"
    for uid in "${main_uids[@]}"; do
        echo "  - $uid"
    done
    
    if [ "$SKIP_DOCS" != true ]; then
        echo ""
        local docs_folder_display="$FOLDER_TITLE"
        if [ -n "$DOCS_FOLDER" ]; then
            docs_folder_display="$DOCS_FOLDER"
        fi
        print_info "Documentation dashboards (folder: $docs_folder_display):"
        for uid in "${docs_uids[@]}"; do
            echo "  - $uid"
        done
    else
        echo ""
        print_info "Skipping documentation dashboards (--skip-docs)"
    fi
    echo ""
    
    read -p "Are you sure you want to continue? (y/N) " -n 1 -r
    echo ""
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Aborted"
        exit 0
    fi
    
    echo ""
    
    local success=0
    local failed=0
    
    for uid in "${uids_to_delete[@]}"; do
        if delete_dashboard "$uid"; then
            ((success++))
        else
            ((failed++))
        fi
    done
    
    echo ""
    print_header "Delete Summary"
    print_success "Successfully deleted: $success"
    if [ $failed -gt 0 ]; then
        print_error "Failed: $failed"
    fi
}

# =============================================================================
# Main
# =============================================================================

main() {
    check_dependencies
    
    # Parse command line arguments
    OVERWRITE=true
    DASHBOARD_DIR="$SCRIPT_DIR"
    COMMAND=""
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -u|--url)
                GRAFANA_URL="$2"
                shift 2
                ;;
            -k|--api-key)
                GRAFANA_API_KEY="$2"
                shift 2
                ;;
            --user)
                GRAFANA_USER="$2"
                shift 2
                ;;
            --password)
                GRAFANA_PASSWORD="$2"
                shift 2
                ;;
            -f|--folder)
                FOLDER_TITLE="$2"
                shift 2
                ;;
            -d|--dashboard-dir)
                DASHBOARD_DIR="$2"
                shift 2
                ;;
            -o|--overwrite)
                OVERWRITE=true
                shift
                ;;
            -n|--no-overwrite)
                OVERWRITE=false
                shift
                ;;
            --insecure)
                INSECURE=true
                shift
                ;;
            --namespace-filter)
                NAMESPACE_FILTER="$2"
                shift 2
                ;;
            --workload-kinds)
                WORKLOAD_KINDS="$2"
                shift 2
                ;;
            --datasource-regex)
                DATASOURCE_REGEX="$2"
                shift 2
                ;;
            --grafana-version)
                GRAFANA_VERSION="$2"
                if [[ "$GRAFANA_VERSION" == "11" ]]; then
                    DASHBOARDS=("${DASHBOARDS_V11[@]}")
                    print_info "Using Grafana v11 compatible dashboards (joinByField transformation)"
                elif [[ "$GRAFANA_VERSION" == "10" ]]; then
                    DASHBOARDS=("${DASHBOARDS_V10[@]}")
                    print_info "Using Grafana v10 compatible dashboards (seriesToColumns transformation)"
                else
                    print_error "Invalid Grafana version: $GRAFANA_VERSION. Use 10 or 11."
                    exit 1
                fi
                shift 2
                ;;
            --skip-docs)
                SKIP_DOCS=true
                shift
                ;;
            --docs-folder)
                DOCS_FOLDER="$2"
                shift 2
                ;;
            -h|--help)
                usage
                ;;
            import|delete|list|status)
                COMMAND="$1"
                shift
                ;;
            *)
                print_error "Unknown option: $1"
                usage
                ;;
        esac
    done
    
    if [ -z "$COMMAND" ]; then
        print_error "No command specified"
        usage
    fi
    
    validate_config
    
    case $COMMAND in
        import)
            cmd_import
            ;;
        delete)
            cmd_delete
            ;;
        list)
            cmd_list
            ;;
        status)
            cmd_status
            ;;
        *)
            print_error "Unknown command: $COMMAND"
            usage
            ;;
    esac
}

main "$@"

