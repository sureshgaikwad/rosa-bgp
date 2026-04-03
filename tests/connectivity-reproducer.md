# Connectivity Issue - Reproducer

**Bug:** VMs using Layer2 CUDN intermittently lose external VPC connectivity

**Nature:** Intermittent - does not reproduce 100% of the time. May exhibit flapping behavior before continuous failure.

## Setup

### 0. Set up cluster

Use https://github.com/rh-mobb/rosa-bgp/tree/25bb3b0c8b8cde1f010a75e859917c0a7282b177 (the head of the `test` branch at time of writing) to set up a cluster, but with some modifications:

### terraform.tfvars

Specify a cluster version of 4.20.17.

#### Set up live-migratable storage

Before running `./oc-virt-install.sh`:

1. Create an FSX for Netapp filesystem in AWS. It should be in the same VPC as your cluster and have the same security groups as your worker nodes. Set the "svm administrative password" to something you will remember. You may need to ensure that its endpoints are published into your route tables.

2. Install the certified Trident operator from OperatorHub.

3. Apply the following YAML to your cluster and wait until the TridentOrchestrator becomes available:

```
apiVersion: trident.netapp.io/v1
kind: TridentOrchestrator
metadata:
  name: trident
  namespace: openshift-operators
spec:
  IPv6: false
  debug: false
  nodePrep:
  - iscsi
  imageRegistry: ''
  k8sTimeout: 30
  namespace: trident
  silenceAutosupport: false
```

4. Once the TridentOchestrator becomes available, apply the following YAML, replacing the Secret password and TridentBackendConfig managementLIF as appropriate.

```
apiVersion: v1
kind: Secret
metadata:
  name: backend-fsx-ontap-san-secret
  namespace: trident
type: Opaque
stringData:
  username: vsadmin
  password: 'REDACTED'
---
apiVersion: trident.netapp.io/v1
kind: TridentBackendConfig
metadata:
  annotations:
  name: fsx-ontap-san
  namespace: trident
spec:
  backendName: fsx-ontap-san
  managementLIF: svm-06e26985c6b4b4cba.fs-0d8bbe72e6e440e73.fsx.us-east-2.amazonaws.com
  credentials:
    name: backend-fsx-ontap-san-secret
  storageDriverName: ontap-san-economy
  svm: fsx
  version: 1
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: trident-csi-san
provisioner: csi.trident.netapp.io
parameters:
  backendType: "ontap-san-economy"
  provisioningType: thin
  snapshots: 'true'
  storagePools: "fsx-ontap-san:.*"
  fsType: "ext4"
mountOptions:
  - discard
allowVolumeExpansion: True
reclaimPolicy: Delete
```

5. Once the TridentBackendConfig shows a good status, make "trident-csi-san" the cluster's only default StorageClass.

6. Now proceed to run `./oc-virt-install.sh`

7. Run `oc apply -f yamls/oc-apply-virt.yaml` (this is missing from the instructions)

### 1. Deploy Test VM

Note that it is highly suspicous that the VM is not live-migratable without the `kubevirt.io/allow-pod-bridge-network-live-migration: "true"` annotation. That may point to the cause of this.

```bash
# Create namespace with CUDN (labels must be set at creation time)
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: cudn-test
  labels:
    cluster-udn: prod
    k8s.ovn.org/primary-user-defined-network: cluster-udn-prod
EOF

# Deploy VM with live migration enabled
cat <<EOF | oc apply -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: test-vm
  namespace: cudn-test
spec:
  running: true
  template:
    metadata:
      annotations:
        kubevirt.io/allow-pod-bridge-network-live-migration: "true"
      labels:
        kubevirt.io/vm: test-vm
    spec:
      domain:
        devices:
          disks:
          - disk:
              bus: virtio
            name: containerdisk
          - disk:
              bus: virtio
            name: cloudinitdisk
          interfaces:
          - name: default
            bridge: {}
        resources:
          requests:
            memory: 1Gi
      networks:
      - name: default
        pod:
          vmNetworkName: cluster-udn-prod
      volumes:
      - containerDisk:
          image: quay.io/containerdisks/fedora:latest
        name: containerdisk
      - cloudInitNoCloud:
          userData: |
            #cloud-config
            password: fedora
            chpasswd: { expire: False }
        name: cloudinitdisk
EOF

# Wait for VM to be ready
oc wait --for=condition=Ready vmi/test-vm -n cudn-test --timeout=300s
```

### 2. Get VM Information

```bash
# Get VM IP
VM_IP=$(oc get vmi test-vm -n cudn-test -o jsonpath='{.status.interfaces[0].ipAddress}')
echo "VM IP: $VM_IP"

# Get initial node placement
INITIAL_NODE=$(oc get vmi test-vm -n cudn-test -o jsonpath='{.status.nodeName}')
echo "Initial node: $INITIAL_NODE"
```

## Reproduction Steps

### 3. Verify External Connectivity (Baseline)

```bash
# First, check OVS flow state (bug may already be present on initial deployment!)
NODE=$INITIAL_NODE
POD=$(oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-node \
  --field-selector spec.nodeName=$NODE -o jsonpath='{.items[0].metadata.name}')

oc exec -n openshift-ovn-kubernetes $POD -c ovn-controller -- \
  ovs-ofctl dump-flows br-ex table=0 | grep "priority=104.*10.100.0.0/16"

# Working state: n_packets > 0, idle_age=0 (actively incrementing)
# Broken state: n_packets=0 or old idle_age (not matching)

# From the EC2 instance that the Terraform deployed to the same VPC as the cluster:
ping -c 10 $VM_IP

# Expected: 0% packet loss
# Actual (if bug present): 50-100% packet loss
# Example output (working):
# 10 packets transmitted, 10 received, 0% packet loss
```

### 4. Verify Internal Connectivity (Baseline)

```bash
# Deploy a test pod on the same CUDN
# Note: Pod automatically uses primary CUDN via namespace label
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: cudn-ping-test
  namespace: cudn-test
spec:
  containers:
  - name: ping
    image: nicolaka/netshoot:latest
    command: ["sleep", "infinity"]
EOF

# Wait for pod
oc wait --for=condition=Ready pod/cudn-ping-test -n cudn-test --timeout=60s

# Test CUDN-to-CUDN connectivity
oc exec -n cudn-test cudn-ping-test -- ping -c 5 $VM_IP

# Expected: 0% packet loss
```

### 5. Perform Live Migration

```bash
# Trigger live migration
virtctl migrate test-vm -n cudn-test

# Wait for migration to complete
oc wait --for=jsonpath='{.status.migrationState.completed}'=true \
  vmi/test-vm -n cudn-test --timeout=300s

# Get new node placement
NEW_NODE=$(oc get vmi test-vm -n cudn-test -o jsonpath='{.status.nodeName}')
echo "New node: $NEW_NODE"

# Verify migration occurred
if [ "$INITIAL_NODE" != "$NEW_NODE" ]; then
  echo "✓ Migration successful: $INITIAL_NODE → $NEW_NODE"
else
  echo "✗ Migration failed: VM still on $INITIAL_NODE"
  exit 1
fi
```

### 6. Test External Connectivity (Check for Bug Manifestation)

```bash
# From the same EC2 instance:
ping -c 10 $VM_IP

# POSSIBLE RESULTS:
# -  0% packet loss: Bug did not manifest, try another migration
# -  50-100% packet loss: Bug manifested
# -  Periodic flapping: Bug manifesting with flapping pattern

# For longer observation to catch flapping:
ping -c 100 $VM_IP
# Flapping pattern shows: works ~60s, fails ~30s, repeats
```

### 7. Test Internal Connectivity (Should Still Work)

```bash
# CUDN-to-CUDN should still work
oc exec -n cudn-test cudn-ping-test -- ping -c 5 $VM_IP

# Expected: 0% packet loss (this continues to work)
```

## Notes

**Possible Root Cause:** Claude Code poked around on the cluster and thinks the following is going on: OVN gateway router fails to perform MAC rewriting on egress packets, causing priority=104 OVS flow to not match. Packets fall through to priority=10 NORMAL flow which fails or is unreliable.
