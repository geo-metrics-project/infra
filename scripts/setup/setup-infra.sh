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

# Namespaces
INFRA_NAMESPACE="geo-infra"
ORY_NAMESPACE="geo-ory"
APP_NAMESPACE="geo-app"
INGRESS_NAMESPACE="ingress-nginx"

RELEASE_NAME="${RELEASE_NAME:-geo-metrics}"

# Create namespaces from YAML file
create_namespaces() {
    log_step "Creating namespaces"
    
    if [[ -f "$PROJECT_ROOT/k8s/namespaces/namespaces.yaml" ]]; then
        kubectl apply -f "$PROJECT_ROOT/k8s/namespaces/namespaces.yaml"
        log_info "Namespaces created from k8s/namespaces/namespaces.yaml"
    else
        log_warn "Namespace file not found at k8s/namespaces/namespaces.yaml"
        log_step "Creating namespaces manually..."
        
        for ns in "$INFRA_NAMESPACE" "$ORY_NAMESPACE" "$APP_NAMESPACE"; do
            if kubectl get namespace "$ns" &>/dev/null; then
                log_info "Namespace '$ns' already exists"
            else
                kubectl create namespace "$ns"
                log_info "Created namespace '$ns'"
            fi
        done
    fi
}

# Setup Helm repositories
setup_helm_repo() {
    log_step "Setting up Helm repositories"
    
    if ! helm repo list | grep -q "^bitnami"; then
        helm repo add bitnami https://charts.bitnami.com/bitnami
        log_info "Added Bitnami repo"
    else
        log_info "Bitnami repo already added"
    fi
    
    if ! helm repo list | grep -q "^ory"; then
        helm repo add ory https://k8s.ory.sh/helm/charts
        log_info "Added Ory repo"
    else
        log_info "Ory repo already added"
    fi

    if ! helm repo list | grep -q "^cetic"; then
        helm repo add cetic https://cetic.github.io/helm-charts
        log_info "Added Cetic repo"
    else
        log_info "Cetic repo already added"
    fi
    
    if ! helm repo list | grep -q "^ingress-nginx"; then
        helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
        log_info "Added ingress-nginx repo"
    else
        log_info "ingress-nginx repo already added"
    fi
    
    if [[ -d "$PROJECT_ROOT/helm/geo-metrics" ]]; then
        log_info "Local geo-metrics chart found at helm/geo-metrics"
    else
        log_warn "Local geo-metrics chart not yet created (will be at helm/geo-metrics)"
    fi
    
    helm repo update
    log_info "Helm repos updated"
}

# Generate and store database passwords
setup_database_secrets() {
    log_step "Setting up database credentials"
    
    log_step "Generating secure random passwords..."
    GEO_APP_PASS=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-32)
    KRATOS_PASS=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-32)
    HYDRA_PASS=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-32)
    KETO_PASS=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-32)
    
    # Always overwrite the secret for PostgreSQL init script
    kubectl delete secret postgres-init-passwords --namespace="$INFRA_NAMESPACE" --ignore-not-found
    kubectl create secret generic postgres-init-passwords \
        --namespace="$INFRA_NAMESPACE" \
        --from-literal=geo-app-password="$GEO_APP_PASS" \
        --from-literal=kratos-password="$KRATOS_PASS" \
        --from-literal=hydra-password="$HYDRA_PASS" \
        --from-literal=keto-password="$KETO_PASS" \
    
    log_info "PostgreSQL init passwords secret created (overwritten if existed)"
    
    # Always overwrite application secrets in respective namespaces
    kubectl delete secret geo-app-db-credentials --namespace="$APP_NAMESPACE" --ignore-not-found
    kubectl create secret generic geo-app-db-credentials \
        --namespace="$APP_NAMESPACE" \
        --from-literal=db-url="postgresql://geo_app_user:$GEO_APP_PASS@${RELEASE_NAME}-postgresql.${INFRA_NAMESPACE}.svc.cluster.local:5432/geo_metrics_db" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    log_info "Created secret: geo-app-db-credentials in $APP_NAMESPACE (overwritten if existed)"
    
    kubectl delete secret kratos-db-credentials --namespace="$ORY_NAMESPACE" --ignore-not-found
    kubectl create secret generic kratos-db-credentials \
        --namespace="$ORY_NAMESPACE" \
        --from-literal=dsn="postgres://kratos_user:$KRATOS_PASS@${RELEASE_NAME}-postgresql.${INFRA_NAMESPACE}.svc.cluster.local:5432/kratos_db?sslmode=disable" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    log_info "Created secret: kratos-db-credentials in $ORY_NAMESPACE (overwritten if existed)"
    
    kubectl delete secret hydra-db-credentials --namespace="$ORY_NAMESPACE" --ignore-not-found
    kubectl create secret generic hydra-db-credentials \
        --namespace="$ORY_NAMESPACE" \
        --from-literal=dsn="postgres://hydra_user:$HYDRA_PASS@${RELEASE_NAME}-postgresql.${INFRA_NAMESPACE}.svc.cluster.local:5432/hydra_db?sslmode=disable" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    log_info "Created secret: hydra-db-credentials in $ORY_NAMESPACE (overwritten if existed)"

    kubectl delete secret keto-db-credentials --namespace="$ORY_NAMESPACE" --ignore-not-found
    kubectl create secret generic keto-db-credentials \
        --namespace="$ORY_NAMESPACE" \
        --from-literal=dsn="postgres://keto_user:$KETO_PASS@${RELEASE_NAME}-postgresql.${INFRA_NAMESPACE}.svc.cluster.local:5432/keto_db?sslmode=disable" \
        --dry-run=client -o yaml | kubectl apply -f -

    log_info "Created secret: keto-db-credentials in $ORY_NAMESPACE (overwritten if existed)"
    
    echo ""
    log_info "All database credentials configured securely (secrets always overwritten)"
}

delete_postgres_pvcs() {
    log_step "Deleting any existing PostgreSQL Deployment/StatefulSet and PVCs in $INFRA_NAMESPACE"

    # Delete PostgreSQL StatefulSet or Deployment if it exists
    if kubectl get statefulset -n "$INFRA_NAMESPACE" | grep -q postgresql; then
        kubectl delete statefulset -n "$INFRA_NAMESPACE" -l app.kubernetes.io/name=postgresql --ignore-not-found
        log_info "Deleted PostgreSQL StatefulSet(s) in $INFRA_NAMESPACE"
    fi
    if kubectl get deployment -n "$INFRA_NAMESPACE" | grep -q postgresql; then
        kubectl delete deployment -n "$INFRA_NAMESPACE" -l app.kubernetes.io/name=postgresql --ignore-not-found
        log_info "Deleted PostgreSQL Deployment(s) in $INFRA_NAMESPACE"
    fi

    # Delete PVCs
    kubectl delete pvc -n "$INFRA_NAMESPACE" -l app.kubernetes.io/name=postgresql --ignore-not-found
    log_info "Deleted PostgreSQL PVCs in $INFRA_NAMESPACE"
}

create_custom_users_and_databases() {
    log_step "Creating custom users and databases in PostgreSQL"

    # Get passwords from the secret
    GEO_APP_PASS=$(kubectl get secret postgres-init-passwords -n "$INFRA_NAMESPACE" -o jsonpath='{.data.geo-app-password}' | base64 -d)
    KRATOS_PASS=$(kubectl get secret postgres-init-passwords -n "$INFRA_NAMESPACE" -o jsonpath='{.data.kratos-password}' | base64 -d)
    HYDRA_PASS=$(kubectl get secret postgres-init-passwords -n "$INFRA_NAMESPACE" -o jsonpath='{.data.hydra-password}' | base64 -d)
    POSTGRES_PASS=$(kubectl get secret ${RELEASE_NAME}-postgresql -n "$INFRA_NAMESPACE" -o jsonpath='{.data.postgres-password}' | base64 -d)
    KETO_PASS=$(kubectl get secret postgres-init-passwords -n "$INFRA_NAMESPACE" -o jsonpath='{.data.keto-password}' | base64 -d)

    # Get the PostgreSQL pod name
    PG_POD=$(kubectl get pods -n "$INFRA_NAMESPACE" -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}')

    kubectl exec -i -n "$INFRA_NAMESPACE" "$PG_POD" -- env PGPASSWORD="$POSTGRES_PASS" psql -U postgres <<EOSQL
CREATE USER geo_app_user WITH PASSWORD '$GEO_APP_PASS';
CREATE DATABASE geo_metrics_db OWNER geo_app_user;
GRANT ALL PRIVILEGES ON DATABASE geo_metrics_db TO geo_app_user;

CREATE USER kratos_user WITH PASSWORD '$KRATOS_PASS';
CREATE DATABASE kratos_db OWNER kratos_user;
GRANT ALL PRIVILEGES ON DATABASE kratos_db TO kratos_user;

CREATE USER hydra_user WITH PASSWORD '$HYDRA_PASS';
CREATE DATABASE hydra_db OWNER hydra_user;
GRANT ALL PRIVILEGES ON DATABASE hydra_db TO hydra_user;

CREATE USER keto_user WITH PASSWORD '$KETO_PASS';
CREATE DATABASE keto_db OWNER keto_user;
GRANT ALL PRIVILEGES ON DATABASE keto_db TO keto_user;
EOSQL

    log_info "Custom users and databases created."
}

# Deploy PostgreSQL
deploy_postgres() {
    log_step "Deploying Bitnami PostgreSQL to $INFRA_NAMESPACE"

    helm upgrade --install "$RELEASE_NAME" bitnami/postgresql \
        --namespace "$INFRA_NAMESPACE" \
        -f "$PROJECT_ROOT/helm/values/values-postgres.yaml" \
        --wait --timeout=5m

    log_info "PostgreSQL deployed in namespace '$INFRA_NAMESPACE'"
}

# Deploy Adminer
deploy_adminer() {
    log_step "Deploying Adminer to $INFRA_NAMESPACE"

    helm upgrade --install adminer cetic/adminer \
        --namespace "$INFRA_NAMESPACE" \
        -f "$PROJECT_ROOT/helm/values/values-adminer.yaml" \
        --wait --timeout=3m

    log_info "Adminer deployed in namespace '$INFRA_NAMESPACE'"
    
    # Apply Ingress
    if [[ -f "$PROJECT_ROOT/k8s/ingress/infra.yaml" ]]; then
        log_step "Applying Adminer Ingress"
        kubectl apply -f "$PROJECT_ROOT/k8s/ingress/infra.yaml"
        log_info "Adminer Ingress applied"
    else
        log_warn "Adminer Ingress manifest not found at k8s/ingress/infra.yaml"
    fi
}

# Display connection information
show_connection_info() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Database Connection Information"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    echo "📊 Adminer (Database UI):"
    echo "  URL: https://adminer.combaldieu.fr"
    echo ""
    
    echo "🗄️  PostgreSQL Superuser:"
    echo "  Username: postgres"
    echo -n "  Password: "
    kubectl get secret ${RELEASE_NAME}-postgresql -n ${INFRA_NAMESPACE} -o jsonpath='{.data.postgres-password}' 2>/dev/null | base64 -d || echo "N/A"
    echo ""
    echo ""
    
    echo "📦 Application Databases Created:"
    echo "  • geo_metrics_db (owner: geo_app_user)"
    echo "  • kratos_db (owner: kratos_user)"
    echo "  • hydra_db (owner: hydra_user)"
    echo ""
    
    echo "🔐 Application Secrets Created:"
    echo "  • geo-app-db-credentials in $APP_NAMESPACE"
    echo "  • kratos-db-credentials in $ORY_NAMESPACE"
    echo "  • hydra-db-credentials in $ORY_NAMESPACE"
    echo ""
    
    echo "💡 To retrieve application database URLs:"
    echo "  kubectl get secret geo-app-db-credentials -n $APP_NAMESPACE -o jsonpath='{.data.db-url}' | base64 -d"
    echo "  kubectl get secret kratos-db-credentials -n $ORY_NAMESPACE -o jsonpath='{.data.dsn}' | base64 -d"
    echo "  kubectl get secret hydra-db-credentials -n $ORY_NAMESPACE -o jsonpath='{.data.dsn}' | base64 -d"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Deploy Ingress Controller
deploy_ingress() {
    log_step "Deploying NGINX Ingress Controller to $INGRESS_NAMESPACE"
    
    # Check if already installed
    if helm list -n "$INGRESS_NAMESPACE" | grep -q "^ingress-nginx"; then
        log_info "NGINX Ingress Controller already installed"
    else
        # Use default values (no custom values file)
        helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
            --namespace "$INGRESS_NAMESPACE" \
            --set controller.service.type=LoadBalancer \
            --wait --timeout=10m
        
        log_info "NGINX Ingress Controller deployed"
    fi
    
    echo ""
    log_step "Waiting for LoadBalancer IP assignment..."
    
    # Wait for external IP
    local count=0
    local max_attempts=30
    
    while [ $count -lt $max_attempts ]; do
        EXTERNAL_IP=$(kubectl get svc ingress-nginx-controller -n "$INGRESS_NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
        
        if [ -n "$EXTERNAL_IP" ]; then
            echo ""
            log_info "LoadBalancer IP assigned: $EXTERNAL_IP"
            echo ""
            echo "Configure your DNS:"
            echo "  *.combaldieu.fr -> $EXTERNAL_IP"
            echo "  adminer.combaldieu.fr -> $EXTERNAL_IP"
            return 0
        fi
        
        echo -n "."
        sleep 2
        ((count++))
    done
    
    echo ""
    log_warn "LoadBalancer IP not assigned yet. Check manually with:"
    echo "  kubectl get svc ingress-nginx-controller -n $INGRESS_NAMESPACE"
}