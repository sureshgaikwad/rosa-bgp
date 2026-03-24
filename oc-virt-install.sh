#!/bin/bash
set -e

NAMESPACE="openshift-cnv"
TIMEOUT_SECONDS=600
POLL_INTERVAL=10

echo "=========================================="
echo "OpenShift Virtualization Installation"
echo "=========================================="

# Check if oc is available and logged in
if ! oc whoami &>/dev/null; then
    echo "ERROR: Not logged into OpenShift cluster"
    echo "Run: oc login \$(terraform output -raw rosa_api_url) -u cluster-admin -p \$(terraform output -raw rosa_cluster_admin_password)"
    exit 1
fi

# Check if already installed
if oc get namespace "$NAMESPACE" &>/dev/null; then
    echo "WARNING: Namespace $NAMESPACE already exists"
    if oc get hco -n "$NAMESPACE" kubevirt-hyperconverged &>/dev/null; then
        echo "OpenShift Virtualization appears to be already installed"
        echo "Current status:"
        oc get hco -n "$NAMESPACE" kubevirt-hyperconverged
        exit 0
    fi
fi

# Step 1: Create namespace and resources
echo ""
echo "[1/5] Creating OpenShift CNV namespace and operator resources..."
cat << 'EOF' | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-cnv
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kubevirt-hyperconverged-group
  namespace: openshift-cnv
spec:
  targetNamespaces:
    - openshift-cnv
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
spec:
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  name: kubevirt-hyperconverged
  channel: stable
  installPlanApproval: Automatic
EOF

echo "✓ Namespace and Subscription created"

# Step 2: Wait for CSV to be ready
echo ""
echo "[2/5] Waiting for ClusterServiceVersion to be ready (timeout: ${TIMEOUT_SECONDS}s)..."
ELAPSED=0
CSV_READY=false

while [ $ELAPSED -lt $TIMEOUT_SECONDS ]; do
    CSV_STATUS=$(oc get csv -n "$NAMESPACE" -o jsonpath='{.items[?(@.spec.displayName=="OpenShift Virtualization")].status.phase}' 2>/dev/null || echo "")

    if [ "$CSV_STATUS" = "Succeeded" ]; then
        CSV_READY=true
        CSV_NAME=$(oc get csv -n "$NAMESPACE" -o jsonpath='{.items[?(@.spec.displayName=="OpenShift Virtualization")].metadata.name}')
        echo "✓ ClusterServiceVersion $CSV_NAME is ready"
        break
    fi

    echo "  Waiting for CSV... (${ELAPSED}s elapsed, status: ${CSV_STATUS:-pending})"
    sleep $POLL_INTERVAL
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

if [ "$CSV_READY" = false ]; then
    echo "ERROR: Timeout waiting for CSV to be ready"
    echo "Check status with: oc get csv -n $NAMESPACE"
    exit 1
fi

# Step 3: Create HyperConverged CR
echo ""
echo "[3/5] Creating HyperConverged custom resource..."
cat << 'EOF' | oc apply -f -
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
spec:
  featureGates:
    deployKubeSecondaryDNS: true
EOF

echo "✓ HyperConverged CR created"

# Step 4: Wait for HyperConverged to be Available
echo ""
echo "[4/5] Waiting for HyperConverged to be Available (timeout: ${TIMEOUT_SECONDS}s)..."
ELAPSED=0
HCO_READY=false

while [ $ELAPSED -lt $TIMEOUT_SECONDS ]; do
    HCO_STATUS=$(oc get hco -n "$NAMESPACE" kubevirt-hyperconverged -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")

    if [ "$HCO_STATUS" = "True" ]; then
        HCO_READY=true
        echo "✓ HyperConverged is Available"
        break
    fi

    # Show progress
    PROGRESS=$(oc get hco -n "$NAMESPACE" kubevirt-hyperconverged -o jsonpath='{.status.conditions[?(@.type=="Progressing")].message}' 2>/dev/null || echo "")
    echo "  Waiting for HyperConverged... (${ELAPSED}s elapsed)"
    if [ -n "$PROGRESS" ]; then
        echo "    Status: $PROGRESS"
    fi

    sleep $POLL_INTERVAL
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

if [ "$HCO_READY" = false ]; then
    echo "ERROR: Timeout waiting for HyperConverged to be Available"
    echo "Check status with: oc get hco -n $NAMESPACE kubevirt-hyperconverged -o yaml"
    exit 1
fi

# Step 5: Verification
echo ""
echo "[5/5] Verification..."
echo ""
echo "=== OpenShift Virtualization Status ==="
oc get hco -n "$NAMESPACE" kubevirt-hyperconverged

echo ""
echo "=== Installed Components ==="
oc get pods -n "$NAMESPACE"

echo ""
echo "=========================================="
echo "✓ OpenShift Virtualization successfully installed!"
echo "=========================================="
echo ""
echo "You can now create VMs in the 'cudn1' namespace."
echo "VMs will use the cluster-udn-prod network (10.100.0.0/16)"
echo "and will be directly routable from vpc1 and vpc2."
echo ""
