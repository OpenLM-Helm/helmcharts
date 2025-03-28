#!/bin/sh

# Permanent repository URLs
API_URL="https://api.github.com/repos/OpenLM-Helm/helmcharts/contents"
RAW_URL="https://raw.githubusercontent.com/OpenLM-Helm/helmcharts/main"

# Default values
CHART_NAME=""
NAMESPACE="openlm"
VALUES=""
DOWNLOAD=false
UNINSTALL=false
EXTRACT=false

# Usage function
show_usage() {
  echo "Usage: $0 -c <CHART_NAME> [-n <NAMESPACE>] [-v <VALUES_FILE>] [-d <COMPONENT>] [-l] [-u] [-e]"
  echo "  -c  Helm chart name"
  echo "  -n  Namespace for the Helm chart (default: openlm)"
  echo "  -v  External values file (optional)"
  echo "  -d  Download a component without installing"
  echo "  -l  List available components (.tgz files) from the repository"
  echo "  -u  Uninstall a Helm chart"
  echo "  -e  Extract the Helm chart to a directory and backup values.yaml"
  echo "  Examples:"
  echo "  Download chart"
  echo "  deploy -d servicenowalertintegration.tgz"
  echo "  Extract "
  echo "  deploy -e -c servicenowalertintegration.tgz "
  echo "  Install chart"
  echo "  deploy -c servicenowalertintegration"
  echo "  Install chart with custom values"
  echo "  deploy -c servicenowalertintegration -v values.yaml"
  echo "  Uninstall"
  echo "  deploy -u -c servicenowalertintegration"
}

# Fetch available components from the GitHub repository
fetch_available_components() {
  echo "Fetching available components from the Helm repository..."
  curl -s "$API_URL" | grep '"name":' | grep '.tgz' | awk -F ': ' '{print $2}' | sed 's/[",]//g'
}

# Download a specified Helm chart component (tgz file)
download_component() {
  component="$1"
  archive="${2:-$component}"  # Use the component name as archive if not specified
  echo "Downloading component: $component ..."
  curl -L -o "$archive" "$RAW_URL/$component"  # Download from the raw GitHub URL
  echo "Download completed: $archive"
}

# Helm install or upgrade with optional values, using RAW_URL for the archive
helm_operation() {
  operation="$1"
  chart_name="$2"
  namespace="$3"
  values="$4"
  err_log="$5"

  # Modify the chart name for install/upgrade
  mod_chart_name=$(echo "$chart_name" | sed 's/_/-/g')  # Replace underscores with dashes in chart name
  archive_url="$RAW_URL/$chart_name.tgz"
  command=" helm $operation $mod_chart_name $archive_url --namespace $namespace"
  [ -n "$values" ] && command="$command -f $values"

  echo "$command"
  eval "$command" 2>> "$err_log"
}
# Uninstall Helm chart
uninstall_chart() {
  chart_name=$(echo "$1" | sed 's/_/-/g')  # Replace underscores with dashes
  namespace="$2"
  echo "Uninstalling chart: $chart_name from namespace $namespace..."
   helm uninstall "$chart_name" --namespace "$namespace"
}

# Get manifest after successful install/upgrade
get_manifest() {
  chart_name="$1"
  manifest_path="$2"
  namespace="$3"

  mod_chart_name=$(echo "$chart_name" | sed 's/_/-/g')  # Ensure the modified name is used
   helm get manifest "$mod_chart_name" -n "$namespace" --debug > "$manifest_path/$mod_chart_name.yaml"
  echo "Manifest saved to $manifest_path/$mod_chart_name.yaml"
}

# Extract a specified Helm chart component (tgz file)
extract_component() {
  component="$1"
  dir_name=$(basename "$component" .tgz)  # Use the component name without .tgz for directory name
  backup_dir="$dir_name/backup"  # Backup directory for values files

  # Create the target and backup directories
  mkdir -p "$dir_name" "$backup_dir"

  # Extract Chart version from the existing Chart.yaml
  chart_version=$(awk '/version:/{print $2}' "$dir_name/Chart.yaml") || chart_version="unknown"

  # Backup existing values.yaml and values.*.yaml files
  for existing_file in "$dir_name/values.yaml" "$dir_name/values."*".yaml"; do
    [ -e "$existing_file" ] && {
      new_name=$(basename "$existing_file" .yaml)."$chart_version.yaml"  # Rename based on Chart version
      echo "Backing up $existing_file to $backup_dir/$new_name"
      cp "$existing_file" "$backup_dir/$new_name"
      mv "$existing_file" "$existing_file.backup"  # Rename current values files to have a .backup extension
    }
  done

  # Remove all contents except values files and the backup directory in the target directory
  find "$dir_name" -mindepth 1 ! -name 'values.yaml' ! -name 'values.*.yaml' ! -name 'backup' -exec rm -rf {} +

  # Extract the new .tgz file into the target directory
  tar -xzvf "$component" -C "$dir_name" || {
    echo "Failed to extract $component"
    return 1
  }

  # Check if the extracted values.yaml exists, and retain it
  extracted_values="$dir_name/values.yaml"
  [ -f "$extracted_values" ] && echo "Extracted values.yaml found and kept." || echo "No extracted values.yaml found in $dir_name after extraction."

  echo "Extraction completed: $dir_name"
}


# Parse options
parse_options() {
  while getopts "hc:n:v:d:lue" opt; do
    case ${opt} in
      c )
        CHART_NAME=$OPTARG
        ;;
      n )
        NAMESPACE=$OPTARG
        ;;
      v )
        VALUES=$OPTARG
        ;;
      d )
        DOWNLOAD=true
        COMPONENT=$OPTARG
        ;;
      l )
        fetch_available_components && exit 0
        ;;
      u )
        UNINSTALL=true
        ;;
      e )
        EXTRACT=true
        ;;
      h )
        show_usage && exit 0
        ;;
    esac
  done
  shift $((OPTIND -1))
}

# Execution starts here
parse_options "$@"

# Log file for errors
ERR_LOG="/tmp/helm_chart/$CHART_NAME/helm_err.log"
mkdir -p "$(dirname "$ERR_LOG")"

# Extract mode
$EXTRACT && extract_component "$CHART_NAME" && exit 0

# Download chart
$DOWNLOAD && download_component "$COMPONENT" && exit 0
# Uninstall chart
$UNINSTALL && uninstall_chart "$CHART_NAME" "$NAMESPACE" && exit 0

# Install or upgrade the Helm chart
helm_operation "install" "$CHART_NAME" "$NAMESPACE" "$VALUES" "$ERR_LOG" || helm_operation "upgrade" "$CHART_NAME" "$NAMESPACE" "$VALUES" "$ERR_LOG"
get_manifest "$CHART_NAME" "/tmp" "$NAMESPACE"

# Clean up error log
rm -rf "$ERR_LOG"

