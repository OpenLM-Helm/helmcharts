#!/bin/bash


# Error handling function
echoerr() {
    echo "$@" >&2
    exit 1
}

# Create namespaces
create_namespace() {
    kubectl get namespace "$1" >/dev/null 2>&1 || kubectl create namespace "$1"
}

# Generate self signed certificates
generate_certificate() {
    CERT_PATH=$1
    CERT_NAME=$2
    [ -z "$CERT_PATH" ] && echoerr "Certificate path not provided"
    [ -z "$CERT_NAME" ] && echoerr "Certificate name not provided"

    mkdir -p "$CERT_PATH" || echoerr "Failed to create certificate directory at $CERT_PATH"

    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$CERT_PATH/$CERT_NAME.key" \
        -out "$CERT_PATH/$CERT_NAME.crt" \
        -subj "/CN=example.com" || echoerr "Failed to generate certificate"

    echo "Certificate successfully created at $CERT_PATH with name $CERT_NAME"
}

# Create K8s secrets
create_secret() {
    cert_name="$1"
    cert_path="$2"
    key_file="$cert_path/$cert_name.key"
    crt_file="$cert_path/$cert_name.crt"

    # Namespace mapping
    case "$cert_name" in
        openlm-lb-cert)
            namespaces=("openlm" "openlm-telemetry")
            ;;
        kafkaui-lb-cert)
            namespaces=("openlm-infrastructure")
            ;;
        *)
            echoerr "No namespace mapping found for certificate: $cert_name"
            ;;
    esac

    for namespace in "${namespaces[@]}"; do
        echo "Creating secret for $cert_name in namespace $namespace..."
        kubectl -n "$namespace" create secret tls "$cert_name" \
            --cert="$crt_file" --key="$key_file" \
            --dry-run=client -o yaml | kubectl apply -f - || \
            echoerr "Failed to create secret for $cert_name in namespace $namespace"
    done
}

# Download the openlm-infrastructure chart
download_openlm_infrastructure() {
    deploy -d openlm-infrastructure.tgz || echoerr "Failed to download openlm-infrastructure"
    echo "openlm-infrastructure successfully downloaded"
}

# Extract the openlm-infrastructure.tgz
extract_openlm_infrastructure() {
    tar -xzvf  openlm-infrastructure.tgz || echoerr "Failed to extract openlm-infrastructure"
    echo "openlm-infrastructure successfully extracted"
}

# handle namespaces and certificates
check_namespaces_and_certificates() {
    # Verify or create namespaces
    for namespace in openlm openlm-infrastructure openlm-telemetry; do
        create_namespace "$namespace"
    done

    # Generate certificates and create secrets
    for cert in $CERT_NAMES; do
        generate_certificate "$CERT_PATH" "$cert"
        create_secret "$cert" "$CERT_PATH"
    done
}

# Show help menu
show_help() {
    cat <<EOF
Usage: $0 -p <path> -n <cert1,cert2,...> [-h]

Options:
  -p <path>        Path to save the certificates
  -n <cert1,cert2> Comma-separated list of certificate names
  -h               Show this help message
EOF
}

# Parse options
while getopts "p:n:h" opt; do
    case "$opt" in
        p) CERT_PATH=$OPTARG ;;
        n) CERT_NAMES=$(echo "$OPTARG" | tr ',' ' ') ;;
        h) show_help; exit 0 ;;
        *) show_help; exit 1 ;;
    esac
done

[ -z "$CERT_PATH" ] && echoerr "Error: Certificate path (-p) is required"
[ -z "$CERT_NAMES" ] && echoerr "Error: Certificate names (-n) are required"


download_openlm_infrastructure
extract_openlm_infrastructure
check_namespaces_and_certificates
