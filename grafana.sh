#!/bin/bash

# Error handling function
echoerr() {
    echo "$@" >&2
    exit 1
}

# Vars
NAMESPACE=""
CHARTS_PATH="/opt/openlm/charts"
VALUES_FILES=""
CHARTS=""
RELEASE_NAMES=""
MANIFESTS=""

# install or upgrade Helm charts
install_or_upgrade_chart() {
    CHART=$1
    VALUES_FILE=$2
    RELEASE_NAME=$3

    helm upgrade --install "$RELEASE_NAME" "$CHARTS_PATH/$CHART" \
        --namespace "$NAMESPACE" ${VALUES_FILE:+--values "$VALUES_FILE"} || \
        echoerr "Failed to install or upgrade chart: $CHART"
    echo "Helm chart installed/upgraded: $CHART as $RELEASE_NAME"
}

#  apply Kubernetes manifests
apply_manifest() {
    MANIFEST=$1
    kubectl apply -f "$CHARTS_PATH/$MANIFEST" -n "$NAMESPACE" || \
        echoerr "Failed to apply manifest: $MANIFEST"
    echo "Manifest applied: $MANIFEST"
}

# Show help
show_help() {
    cat <<EOF
Usage: $0 -n <namespace> -c <charts_path> -d <chart1,chart2,...> -v <values1,values2,...> -r <release1,release2,...> -m <manifest1,manifest2,...> [-h]

Options:
  -n <namespace>            Kubernetes namespace
  -c <charts_path>          Path to the charts directory (default: /opt/openlm/charts)
  -d <chart1,chart2,...>    Comma-separated list of charts to install/upgrade
  -v <values1,values2,...>  Comma-separated list of values files
  -r <release1,release2,...> Comma-separated list of release names
  -m <manifest1,manifest2,...> Comma-separated list of manifests to apply
  -h                        Show this help message
EOF
}

# Parse options
while getopts "n:c:d:v:r:m:h" opt; do
    case "$opt" in
        n) NAMESPACE=$OPTARG ;;
        c) CHARTS_PATH=$OPTARG ;;
        d) CHARTS=$(echo "$OPTARG" | tr ',' ' ') ;;
        v) VALUES_FILES=$(echo "$OPTARG" | tr ',' ' ') ;;
        r) RELEASE_NAMES=$(echo "$OPTARG" | tr ',' ' ') ;;
        m) MANIFESTS=$(echo "$OPTARG" | tr ',' ' ') ;;
        h) show_help; exit 0 ;;
        *) show_help; exit 1 ;;
    esac
done

# Ensure the required namespace is provided
[ -z "$NAMESPACE" ] && echoerr "Error: Namespace (-n) is required"

# Split and process charts, values, and release names
CHART_LIST=$(echo "$CHARTS" | tr ',' ' ')
VALUES_LIST=$(echo "$VALUES_FILES" | tr ',' ' ')
RELEASE_LIST=$(echo "$RELEASE_NAMES" | tr ',' ' ')

CHART_ARRAY=($CHART_LIST)
VALUES_ARRAY=($VALUES_LIST)
RELEASE_ARRAY=($RELEASE_LIST)

# Install or upgrade charts
for i in "${!CHART_ARRAY[@]}"; do
    install_or_upgrade_chart "${CHART_ARRAY[$i]}" "${VALUES_ARRAY[$i]}" "${RELEASE_ARRAY[$i]}"
done

# Apply manifests
MANIFEST_LIST=$(echo "$MANIFESTS" | tr ',' ' ')
for manifest in $MANIFEST_LIST; do
    apply_manifest "$manifest"
done

