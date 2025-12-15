#!/bin/bash
set -euo pipefail

# Colors and logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}✓${NC} $1"; }
log_error() { echo -e "${RED}✗${NC} $1" >&2; }
log_warn() { echo -e "${YELLOW}⚠${NC} $1"; }
log_step() { echo -e "${BLUE}==>${NC} $1"; }

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Infra Namespace
INFRA_NAMESPACE="geo-infra"
RELEASE_NAME="${RELEASE_NAME:-geo-metrics}"

# Create infra namespace if it doesn't exist
create_namespace() {
    log_step "Ensuring infra namespace exists"

    if kubectl get namespace "$INFRA_NAMESPACE" &>/dev/null; then
        log_info "Namespace '$INFRA_NAMESPACE' already exists"
    else
        kubectl create namespace "$INFRA_NAMESPACE"
        log_info "Created namespace '$INFRA_NAMESPACE'"
    fi
}

# Install and configure MetalLB using Helm
setup_metallb() {
    log_step "Installing MetalLB with Helm"

    # Add MetalLB Helm repo if not present
    if ! helm repo list | grep -q "^metallb"; then
        helm repo add metallb https://metallb.github.io/metallb
        log_info "Added MetalLB Helm repo"
    else
        log_info "MetalLB Helm repo already added"
    fi

    helm repo update

    # Install MetalLB if not present
    if ! helm list -n metallb-system | grep -q "^metallb"; then
        helm install metallb metallb/metallb --namespace metallb-system --create-namespace
        log_info "MetalLB installed via Helm"
    else
        log_info "MetalLB already installed via Helm"
    fi

    # Apply MetalLB config
    if kubectl get ipaddresspool -n metallb-system my-ip-pool &>/dev/null; then
        log_info "MetalLB IPAddressPool already configured"
    else
        kubectl apply -f "$PROJECT_ROOT/k8s/metallb/metallb.yaml"
        log_info "Applied MetalLB configuration"
    fi
}

# Deploy Ingress Controller using Helm
deploy_ingress() {
    local INGRESS_NAMESPACE="$INFRA_NAMESPACE"
    log_step "Deploying NGINX Ingress Controller to $INGRESS_NAMESPACE"

    # Add ingress-nginx Helm repo if not present
    if ! helm repo list | grep -q "^ingress-nginx"; then
        helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
        log_info "Added ingress-nginx Helm repo"
    else
        log_info "ingress-nginx Helm repo already added"
    fi

    helm repo update

    # Check if already installed
    if helm list -n "$INGRESS_NAMESPACE" | grep -q "^ingress-nginx"; then
        log_info "NGINX Ingress Controller already installed"
    else
        helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
            --namespace "$INGRESS_NAMESPACE" \
            --create-namespace \
            --set controller.service.type=LoadBalancer \
            --wait --timeout=10m

        log_info "NGINX Ingress Controller deployed"
    fi

    echo ""
    log_step "Waiting for LoadBalancer IP assignment..."

    # Wait for external IP
    local count=0
    local max_attempts=30

    set +e  # Disable exit on error for this loop
    while [ $count -lt $max_attempts ]; do
        EXTERNAL_IP=$(kubectl get svc ingress-nginx-controller -n "$INGRESS_NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
        if [ -n "$EXTERNAL_IP" ]; then
            echo ""
            log_info "LoadBalancer IP assigned: $EXTERNAL_IP"
            echo ""
            echo "Configure your DNS:"
            echo "  *.combaldieu.fr -> $EXTERNAL_IP"
            set -e  # Re-enable exit on error
            return 0
        fi

        echo -n "."
        sleep 2
        ((count++))
    done
    set -e  # Re-enable exit on error

    echo ""
    log_warn "LoadBalancer IP not assigned yet. Check manually with:"
    echo "  kubectl get svc ingress-nginx-controller -n $INGRESS_NAMESPACE"
    return 0
}

if [[ $# -gt 0 ]]; then
    "$@"
else
    create_namespace
    setup_metallb
    setup_ingress
fi