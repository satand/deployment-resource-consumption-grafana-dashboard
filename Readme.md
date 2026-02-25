# Resource Consumption Analysis - Grafana Dashboards

A comprehensive suite of Grafana dashboards for analyzing Kubernetes workload resource consumption, with simulation profiles for rightsizing recommendations.

## Dashboards

### 📊 Namespace Overview Dashboard
- **Files**: `grafana-dashboard.json` (v10.x) / `grafana-dashboard-v11.json` (v11.x)
- **UID**: `workload-resource-analysis`
- Provides namespace-level overview of all workloads
- CPU and Memory resource usage tables with min/max/avg statistics
- Resource utilization and risk analysis
- Limit/Request ratio analysis
- Time distribution by resource zone
- **Simulation rows** for Normal and Aggressive optimization profiles

### 🔍 Workload Details Dashboard (`grafana-dashboard-workload.json`)
- **UID**: `workload-resource-workload`
- Deep-dive analysis for individual workloads
- Real-time CPU/Memory usage time series with request/limit lines
- Gauge panels for utilization percentages and limit/request ratios
- Per-pod breakdown for troubleshooting
- **Simulation rows** with Normal and Aggressive profile recommendations

## Documentation Dashboards

### 📖 Namespace Overview Documentation (`grafana-dashboard-docs.json`)
- **UID**: `workload-resource-analysis-docs`
- Detailed explanations for all panels in the Namespace Overview Dashboard
- Threshold definitions and color interpretations
- Formula descriptions and usage guidance

### 📖 Workload Details Documentation (`grafana-dashboard-workload-docs.json`)
- **UID**: `workload-resource-workload-docs`
- Detailed explanations for all panels in the Workload Details Dashboard
- Threshold definitions for gauges and simulated values

## Simulation Profiles

| Profile | CPU Request | CPU Limit | Memory Request | Memory Limit |
|---------|-------------|-----------|----------------|--------------|
| **Normal** | P90 | P99 × 1.5 | P95 | Max × 1.2 |
| **Aggressive** | P95 × 1.1 | Max × 1.25 | Max | Max × 1.25 |

## Management Script

### `manage-dashboards.sh`

Bash script for managing dashboards on a Grafana server.

#### Commands

```bash
# Import all dashboards to a folder
./manage-dashboards.sh import --url https://grafana.example.com --folder "My Folder" --user admin --password secret

# Delete dashboards from a folder
./manage-dashboards.sh delete --url https://grafana.example.com --folder "My Folder" --user admin --password secret

# List dashboards in a folder
./manage-dashboards.sh list --url https://grafana.example.com --folder "My Folder" --user admin --password secret

# Check connection status
./manage-dashboards.sh status --url https://grafana.example.com --user admin --password secret
```

#### Options

| Option | Description |
|--------|-------------|
| `--url URL` | Grafana server URL (or `GRAFANA_URL` env var) |
| `--folder NAME` | Target folder name |
| `--user USER` | Username for basic auth (or `GRAFANA_USER` env var) |
| `--password PASS` | Password for basic auth (or `GRAFANA_PASSWORD` env var) |
| `--api-key KEY` | API key/Service Account token (or `GRAFANA_API_KEY` env var) |
| `--insecure` | Skip TLS certificate verification |
| `--namespace-filter REGEX` | Filter namespaces by regex (default: `.*` = all) |
| `--workload-kinds KINDS` | Pod owner kinds to include (default: `ReplicaSet\|ReplicationController\|StatefulSet`) |
| `--datasource-regex REGEX` | Filter Prometheus datasources by regex, e.g., `/.*-prod.*/` (default: `""` = all) |
| `--grafana-version VER` | Target Grafana version: `10` or `11` (default) |
| `--skip-docs` | Skip importing documentation dashboards |
| `--docs-folder TITLE` | Import documentation dashboards to a separate folder |

#### Examples

```bash
# Import with namespace filtering (only prod namespaces)
./manage-dashboards.sh import --url https://grafana.example.com \
  --folder "Production" --user admin --password secret \
  --namespace-filter "^prod-.*"

# Import with custom workload kinds
./manage-dashboards.sh import --url https://grafana.example.com \
  --folder "Custom" --user admin --password secret \
  --workload-kinds "Deployment|StatefulSet|DaemonSet"

# Use environment variables
export GRAFANA_URL="https://grafana.example.com"
export GRAFANA_USER="admin"
export GRAFANA_PASSWORD="secret"
./manage-dashboards.sh import --folder "My Folder"

# Import for Grafana v11+ (uses joinByField transformation)
./manage-dashboards.sh import --url https://grafana.example.com \
  --folder "My Folder" --user admin --password secret \
  --grafana-version 11

# Import with datasource filter (only show production Prometheus instances)
./manage-dashboards.sh import --url https://grafana.example.com \
  --folder "Production" --user admin --password secret \
  --datasource-regex "/.*-prod.*/"

# Import documentation dashboards to a separate folder
./manage-dashboards.sh import --url https://grafana.example.com \
  --folder "Dashboards" --docs-folder "Documentation" \
  --user admin --password secret
```

## Requirements

- **Grafana 11.x+**: Use default dashboards (`--grafana-version 11` or omit the flag)
- **Grafana 10.x**: Use v10 dashboards (`--grafana-version 10`)
- Prometheus datasource with Kubernetes metrics:
  - `container_cpu_usage_seconds_total`
  - `container_memory_working_set_bytes`
  - `kube_pod_info`
  - `kube_pod_container_resource_requests`
  - `kube_pod_container_resource_limits`

## Version Compatibility

The Namespace Overview dashboard uses table transformations that differ between Grafana versions:

| Grafana Version | Dashboard File | Transformations |
|-----------------|----------------|-----------------|
| 10.x | `grafana-dashboard.json` | `seriesToColumns`, `filterByValue` (v10 format) |
| 11.x+ | `grafana-dashboard-v11.json` | `joinByField`, `filterByValue` (v11 format) |

**Key transformation changes in Grafana v11:**
- `seriesToColumns` was renamed to `joinByField` (with added `mode` option)
- `filterByValue` requires `"options": {}` inside the filter config

Using the wrong version will result in transformation rendering errors.
