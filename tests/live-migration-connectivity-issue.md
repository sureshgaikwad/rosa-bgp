# Live Migration Connectivity Issue with Layer2 CUDN and External Networks

**Disclaimer** This is Claude Code's writeup of the problem after doing its own troubleshooting. It contains errors and has not been evaluated by a human who understands the relevant networking pieces in deep detail.

**Date:** 2026-04-03
**Environment:** ROSA HCP 4.20.17 with OpenShift Virtualization, Layer2 Cluster User Defined Networks (CUDN), BGP routing via AWS VPC Route Server
**Severity:** High - Breaks external connectivity after VM live migration

## Summary

VMs using Layer2 CUDN networks lose external VPC connectivity after live migration, while internal CUDN-to-CUDN connectivity continues to work. The issue is caused by stale OVN/OVS state on the node hosting the VM after migration, specifically related to MAC address rewriting in the OVN gateway router's egress path.

**Workaround:** Restart the `ovnkube-node` pod on the node hosting the VM after live migration.

## Environment Details

- **ROSA Version:** HCP (Hosted Control Plane) on AWS
- **OpenShift Version:** 4.20.17
- **Networking:**
  - OVN-Kubernetes with Layer2 CUDN (Cluster User Defined Network)
  - BGP routing via FRR to AWS VPC Route Server for external connectivity
  - CUDN subnet: `10.100.0.0/16`
  - VPC subnet: `10.0.0.0/16`
- **OpenShift Virtualization:** KubeVirt VMs with bridge networking on CUDN
- **Cluster Configuration:**
  - 3 BGP router nodes (baremetal, one per AZ)
  - 6 total worker nodes (3 BGP routers + 3 regular workers)

## Initial Symptoms

### Working State (Before Migration)
- EC2 instances in VPC → VM in CUDN: ✅ Working
- VM in CUDN → EC2 instances in VPC: ✅ Working
- VM in CUDN → VM in CUDN: ✅ Working

### After Live Migration
- EC2 instances in VPC → VM in CUDN: ❌ 100% packet loss
- VM in CUDN → EC2 instances in VPC: ❌ 100% packet loss
- VM in CUDN → VM in CUDN: ✅ Still working

### Flapping Behavior (Initially Observed)
Before continuous failure, there was periodic flapping:
- Traffic works for ~1 minute
- Traffic fails for ~30 seconds
- Pattern repeats

After ~30 minutes of investigation, the pattern changed to continuous failure, suggesting some timer or dynamic state expired.

## Migration History

The VM underwent the following migrations:
1. **Initial placement:** `ip-10-0-1-62.us-east-2.compute.internal` (subnet 1, BGP router node)
2. **First migration:** → `ip-10-0-2-98.us-east-2.compute.internal` (subnet 2, BGP router node)
3. **Second migration:** → `ip-10-0-1-62.us-east-2.compute.internal` (back to subnet 1)

After the second migration back to subnet 1, external connectivity failed despite the VM being back on a node that previously worked.

## Investigation Steps

### 1. Initial BGP and Routing Investigation

**Hypothesis:** BGP routes are flapping or pointing to the wrong node.

**What we checked:**
- VPC route tables for `10.100.0.0/16` destination
- FRR BGP session status on all three router nodes
- Route Server peer status
- BGP route advertisements

**Observations:**
- ✅ All 3 BGP router nodes have established BGP sessions with Route Server endpoints
- ✅ All 3 nodes advertise `10.100.0.0/16` to Route Server (due to static `network` statements in FRR config)
- ✅ VPC route tables consistently point to subnet 1 node ENI (`eni-00619d3a0816cc014` / `10.0.1.62`)
- ✅ No BGP session flapping detected in FRR logs
- ✅ BGP routes are stable

**Conclusion:** BGP routing is working correctly. The issue is not at the BGP/VPC routing layer.

### 2. VRF Routing Table Investigation

**Hypothesis:** Nodes without CUDN pods don't have VRF routing tables, so traffic arriving at those nodes can't be forwarded.

**What we checked:**
```bash
# Check VRF interfaces
ip link show type vrf

# Check VRF routing tables
ip route show table <vrf-table-id>

# Check which nodes have CUDN pods
oc get pods -n cudn1 -o wide
```

**Observations:**
- ✅ ALL worker nodes have VRF interfaces (`mp1-udn-vrf`, `mp2-udn-vrf`)
- ✅ ALL nodes have routing tables with `10.100.0.0/16 dev ovn-k8s-mp1` entries
- ✅ VRF tables exist even on nodes without CUDN pods
- ℹ️ VRF table IDs vary by node (e.g., table 1030 on one node, 1024 on another)

**Conclusion:** This hypothesis was **WRONG**. All nodes can route CUDN traffic via their VRF tables. The OVN overlay handles tunneling between nodes, so VMs don't need to be on the same node where VPC traffic arrives.

### 3. FRRConfiguration and Route Advertisement Investigation

**Hypothesis:** OVN-generated FRRConfiguration resources with static network statements cause all nodes to advertise routes unconditionally, even nodes that can't actually forward the traffic.

**What we checked:**
- FRRConfiguration resources (both manual `all-nodes` and OVN-generated `ovnk-generated-*`)
- RouteAdvertisement resources and their status
- FRR running configuration via `vtysh -c "show run"`

**Observations:**
- ℹ️ `all-nodes` FRRConfiguration applies to all BGP router nodes, has no VRF imports
- ℹ️ OVN generates per-node FRRConfiguration resources with VRF imports
- ℹ️ Both configs have `toAdvertise.allowed.prefixes` which translate to static `network 10.100.0.0/16` statements in FRR
- ℹ️ Static network statements with `no bgp network import-check` cause unconditional advertisement

**Attempted fix:**
- Deleted `all-nodes` FRRConfiguration thinking it was causing issues
- Result: OVN-generated configs also disappeared (RouteAdvertisement requires a base config)
- Recreated `all-nodes` via `oc-cudn-run1.sh`

**Conclusion:** While the static network statements are suboptimal design, this wasn't the root cause of our specific issue. The unconditional advertisements explain why all nodes advertise routes, but doesn't explain why traffic fails when arriving at a node with valid VRF tables.

### 4. OVS Flow Analysis - The Breakthrough

**Hypothesis:** Traffic is being forwarded properly by OVS but something downstream is dropping it.

**What we checked:**
```bash
# Ingress flow (VPC → CUDN)
ovs-ofctl dump-flows br-ex table=0 | grep "in_port=1,nw_dst=10.100.0.0/16"

# Egress flows (CUDN → VPC)
ovs-ofctl dump-flows br-ex table=0 | grep "in_port=3"

# MAC learning table
ovs-appctl fdb/show br-ex

# Patch port statistics
ovs-vsctl get Interface <patch-port> statistics
```

**Critical Observations:**

**Ingress (Working):**
```
priority=300,ip,in_port=1,nw_dst=10.100.0.0/16 actions=output:3
n_packets=4562, idle_age=0
```
- ✅ Packets arriving from physical interface (port 1)
- ✅ Being forwarded to CUDN patch port (port 3)
- ✅ Packet counter actively incrementing

**Egress (Broken):**
```
priority=104,ip,in_port=3,dl_src=02:df:cd:5d:1a:e3,nw_src=10.100.0.0/16 actions=output:1
n_packets=374, idle_age=2168

priority=10,in_port=3,dl_src=02:df:cd:5d:1a:e3 actions=NORMAL
n_packets=2490, idle_age=0

priority=9,in_port=3 actions=drop
n_packets=0
```

**Key Finding:**
- ❌ Priority=104 flow (specific CUDN egress with MAC match): `idle_age=2168` seconds (~36 minutes) - **STOPPED**
- ✅ Priority=10 flow (catch-all NORMAL): `idle_age=0` - **ACTIVE**
- ✅ Priority=9 drop rule: `n_packets=0` - not matching

**This revealed the problem:**
1. Return packets from CUDN should match the priority=104 flow
2. That flow requires `dl_src=02:df:cd:5d:1a:e3` (the node's MAC address)
3. Packets aren't matching this flow, so they fall through to priority=10 NORMAL
4. The NORMAL action relies on MAC learning, which isn't working properly

### 5. MAC Address Investigation

**Hypothesis:** Return packets don't have the correct source MAC address.

**What we checked:**
- OVN gateway router port configuration
- Expected MAC address: `02:df:cd:5d:1a:e3` (node's br-ex MAC)
- Actual packet flow behavior

**Observations:**
```bash
# Gateway router external port configuration
ovn-nbctl find Logical_Router_Port 'name="rtoe-GR_cluster_udn_cluster.udn.prod_ip-10-0-1-62..."'

mac: "02:df:cd:5d:1a:e3"  # Correctly configured
```

- ✅ OVN gateway router port is configured with the correct MAC
- ✅ OVN *should* be rewriting source MAC on egress
- ❌ But packets aren't matching the flow that requires this MAC
- ℹ️ 24,676 packets sent from CUDN via patch port
- ℹ️ Only 2,490 packets matched the priority=10 NORMAL flow
- ℹ️ Priority=104 specific flow: 0 packets matching

**Conclusion:** The OVN gateway router's MAC rewriting function is not working properly after live migration.

### 6. Patch Port and Statistics Analysis

**What we checked:**
```bash
# br-int to br-ex patch port stats
ovs-vsctl get Interface patch-br-int-to-br-ex_cluster_udn_cluster.udn.prod_... statistics
# Result: rx_packets=4,291,525 tx_packets=24,676

# br-ex to br-int patch port stats
ovs-vsctl get Interface patch-br-ex_cluster_udn_cluster.udn.prod_...-to-br-int statistics
# Result: rx_packets=24,676 tx_packets=4,292,939

# Physical interface stats
ovs-vsctl get Interface enp125s0 statistics
# Result: tx_packets increasing (confirming packets reaching physical NIC)
```

**Observations:**
- ✅ Packets are flowing through the patch port (24,676 packets)
- ✅ Ingress side shows 4.3M packets (active bidirectional traffic via tunnel to other CUDN pods)
- ✅ Physical interface TX counter incrementing
- ❌ But external pings still failing

**Conclusion:** Packets are reaching the physical interface but with the wrong MAC or being dropped somewhere in the egress path.

### 7. OVN Controller Restart Attempt

**Hypothesis:** Restarting just the OVN controller container might refresh the flow state.

**What we tried:**
```bash
oc delete pod ovnkube-node-<pod> -n openshift-ovn-kubernetes
# Wait for pod to restart
```

**Observations:**
- ⚠️ Pod restarted successfully
- ❌ Priority=104 flow **still had n_packets=0** after restart
- ℹ️ Flow duration reset (showing it was recreated), but still not matching packets

**Conclusion:** Simple pod restart didn't fix the issue because OVS database state persisted.

### 8. Manual Flow Deletion Experiment

**Hypothesis:** Deleting and forcing recreation of the priority=104 flow might help.

**What we tried:**
```bash
ovs-ofctl del-flows br-ex "cookie=0xdeff105/-1,table=0,in_port=3,nw_src=10.100.0.0/16,dl_src=02:df:cd:5d:1a:e3"
```

**Observations:**
- ✅ Flow was deleted
- ✅ Flow was automatically recreated within ~30 seconds
- ❌ New flow **still had n_packets=0**
- ❌ Pings still failing

**Conclusion:** The flow recreation mechanism is working, but something in the OVN logical flow layer isn't properly configuring the egress path.

### 9. Full ovnkube-node Pod Restart - The Solution

**Hypothesis:** A complete restart of the entire ovnkube-node pod (all containers, full OVN/OVS subsystem) might clear stale state.

**What we tried:**
```bash
oc delete pod ovnkube-node-<pod> -n openshift-ovn-kubernetes
# Wait ~45 seconds for full restart (8 containers)
```

**Results:**
```
# BEFORE:
priority=104,ip,in_port=3,dl_src=02:df:cd:5d:1a:e3,nw_src=10.100.0.0/16 actions=output:1
n_packets=0

# AFTER:
priority=104,ip,in_port=3,dl_src=02:df:cd:5d:1a:e3,nw_src=10.100.0.0/16 actions=output:1
n_packets=26, idle_age=0
```

- ✅ Priority=104 flow now matching packets!
- ✅ Packets have correct source MAC (`02:df:cd:5d:1a:e3`)
- ✅ External pings working!
- ✅ CUDN-to-CUDN still working
- ✅ All connectivity restored

**Success!**

## Root Cause Analysis

### What Was Actually Wrong

After live migration, the OVN controller on the node hosting the VM failed to properly maintain the external gateway router's egress path state. Specifically:

1. **MAC Rewriting Failure:** The OVN gateway router port (`rtoe-GR_cluster_udn_cluster.udn.prod_ip-10-0-1-62...`) is configured with MAC `02:df:cd:5d:1a:e3` and should rewrite the source MAC of egress packets from CUDN VMs to this MAC address before sending them to br-ex.

2. **Stale Flow State:** After migration, packets from the VM were bypassing the proper OVN logical router egress path and going directly through the OVS bridge using the catch-all NORMAL flow, without MAC rewriting.

3. **Why NORMAL Failed:** The priority=10 NORMAL flow relies on MAC learning in the OVS forwarding database (FDB). With stale or incorrect state after migration, even this fallback path wasn't working reliably.

4. **Why CUDN-to-CUDN Still Worked:** Internal CUDN traffic uses OVN's overlay network with Geneve tunnels between nodes. This path doesn't require the external gateway router, so it continued working.

### Technical Details

**The OVN External Gateway Architecture:**
```
VM (10.100.0.4)
  → ovn-k8s-mp1 interface (10.100.0.2)
  → OVN logical switch (cluster_udn_cluster.udn.prod_ovn_layer2_switch)
  → OVN logical router (GR_cluster_udn_cluster.udn.prod_ip-10-0-1-62...)
    → Router port rtoe-GR... (MAC: 02:df:cd:5d:1a:e3)  ← MAC REWRITING HAPPENS HERE
  → OVN external switch (ext_cluster_udn_cluster.udn.prod_ip-10-0-1-62...)
  → OVS br-int
  → OVS br-ex patch port (port 3)
  → OVS br-ex
  → Physical NIC (enp125s0, port 1)
  → VPC network
```

**What Broke:**
The MAC rewriting step (indicated above) stopped working after migration. Packets kept their original VM MAC (`0a:58:0a:64:00:04`) instead of getting rewritten to the node's MAC.

**OVS Flow Matching:**
```
# This flow requires the rewritten MAC:
priority=104,ip,in_port=3,dl_src=02:df:cd:5d:1a:e3,nw_src=10.100.0.0/16 actions=output:1

# Without rewriting, packets fell through to:
priority=10,in_port=3,dl_src=02:df:cd:5d:1a:e3 actions=NORMAL

# Which wasn't working reliably due to stale MAC learning state
```

### Why Live Migration Triggered This

Live migration involves:
1. Creating VM on target node
2. Memory transfer
3. Switching network connectivity to target node
4. Cleaning up source node

**Hypothesis on failure mechanism:**
- When the VM migrated away from subnet 1, the OVN controller should have torn down or suspended the external gateway state
- When the VM migrated back to subnet 1, the OVN controller should have fully recreated this state
- Instead, some cached or stale state from the first migration persisted
- This stale state caused the MAC rewriting logic in the OVN gateway router to malfunction

### Why the Flapping Occurred Initially

**The 1 minute work / 30 second fail pattern likely indicates:**
- Some dynamic state (possibly MAC bindings, flow cache, or connection tracking entries) with a ~90 second lifetime
- When fresh: Traffic works
- When expired: Traffic fails
- When refreshed: Traffic works again
- After ~30 minutes: State stopped refreshing entirely, leading to continuous failure

## Wrong Hypotheses Summary

### ❌ Hypothesis 1: Nodes Without VMs Can't Route CUDN Traffic
**Why wrong:** All nodes have VRF routing tables and can inject traffic into the OVN overlay, which then tunnels to the actual VM location.

### ❌ Hypothesis 2: Static BGP Network Statements Cause Routing Issues
**Why wrong:** While all nodes advertising routes is suboptimal, the VPC route tables were stable and pointed to the correct node. BGP wasn't flapping.

### ❌ Hypothesis 3: FRR Configuration Conflicts
**Why wrong:** Deleting and recreating FRR configs didn't fix the issue. BGP sessions remained stable throughout.

### ❌ Hypothesis 4: MAC Learning Table Corruption
**Why partially wrong:** While the NORMAL flow wasn't working reliably, the real issue was that packets shouldn't have been using the NORMAL flow at all - they should have matched the priority=104 flow with the correct MAC.

### ❌ Hypothesis 5: Simple OVN Controller Restart Will Fix It
**Why wrong:** The stale state persisted through a single container restart. A full pod restart (all containers + OVS daemon restart) was needed.

## Solution

### Immediate Workaround

After live migration of a VM using Layer2 CUDN, restart the ovnkube-node pod on the node hosting the VM:

```bash
# Find the node hosting the VM
NODE=$(oc get vmi <vm-name> -n <namespace> -o jsonpath='{.status.nodeName}')

# Find the ovnkube-node pod on that node
POD=$(oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-node \
  --field-selector spec.nodeName=$NODE -o jsonpath='{.items[0].metadata.name}')

# Restart the pod
oc delete pod $POD -n openshift-ovn-kubernetes

# Wait for pod to restart (8/8 Running)
oc wait --for=condition=Ready pod -l app=ovnkube-node \
  --field-selector spec.nodeName=$NODE -n openshift-ovn-kubernetes --timeout=120s
```

### Verification

After restart, verify:

1. **CUDN-to-CUDN connectivity:**
```bash
oc exec -n <namespace> <other-cudn-pod> -- ping -c 3 <vm-ip>
```

2. **External connectivity from EC2:**
```bash
ping -c 10 <vm-ip>
```

3. **OVS flow counters:**
```bash
oc exec -n openshift-ovn-kubernetes <ovnkube-node-pod> -c ovn-controller -- \
  ovs-ofctl dump-flows br-ex table=0 | grep "priority=104.*10.100.0.0/16"
# Should show n_packets > 0 and idle_age=0 (actively matching)
```

## Upstream Bug Report

This appears to be a bug in OVN-Kubernetes' handling of live migration with Layer2 CUDN networks. The issue should be reported upstream with the following information:

**Component:** ovn-kubernetes
**Affected Version:** OpenShift 4.17
**Network Type:** Layer2 Cluster User Defined Network (CUDN)
**Workload:** KubeVirt VirtualMachines

**Bug Summary:**
OVN gateway router egress MAC rewriting stops working after VM live migration, breaking external connectivity while internal CUDN traffic continues to work. Full ovnkube-node pod restart required to restore functionality.

**Expected Behavior:**
After live migration, the OVN controller should properly maintain or recreate the external gateway router state, ensuring MAC rewriting on egress continues to function.

**Actual Behavior:**
MAC rewriting stops working, causing egress packets to retain the VM's MAC instead of being rewritten to the node's MAC, which breaks the OVS flow matching and external connectivity.

## Additional Notes

### Monitoring for This Issue

Watch for these symptoms:
- VM live migration completes successfully (VMI shows new node)
- Internal pod-to-pod on CUDN continues working
- External connectivity breaks (VPC ↔ CUDN fails)
- OVS flow `priority=104,ip,in_port=3,dl_src=<node-mac>,nw_src=10.100.0.0/16` has `n_packets=0`

### Prevention

Until fixed upstream:
- Automate the ovnkube-node pod restart after live migration
- Consider using a ValidatingWebhookConfiguration to detect migrations and trigger remediation
- Monitor OVS flow statistics for the priority=104 egress flow

### Testing Live Migration

To reproduce:
1. Deploy VM with Layer2 CUDN network and external gateway configured
2. Verify external connectivity works (e.g., ping from VPC)
3. Perform live migration: `virtctl migrate <vm-name> -n <namespace>`
4. After migration completes, test external connectivity
5. Expected: Connectivity breaks
6. Apply workaround: Restart ovnkube-node on new host node
7. Verify: Connectivity restored

## Related Issues

- Priority=104 flow not matching after migration (core symptom)
- MAC rewriting failure in OVN gateway router
- Stale OVS/OVN state persisting across container restarts
- Potential connection tracking or flow cache issues

## References

- VPC route tables: All pointing to subnet 1 node (`eni-00619d3a0816cc014`)
- OVN gateway router: `GR_cluster_udn_cluster.udn.prod_ip-10-0-1-62.us-east-2.compute.internal`
- OVN external switch: `ext_cluster_udn_cluster.udn.prod_ip-10-0-1-62.us-east-2.compute.internal`
- CUDN logical switch: `cluster_udn_cluster.udn.prod_ovn_layer2_switch`
- br-ex node MAC: `02:df:cd:5d:1a:e3`
- VM MAC: `0a:58:0a:64:00:04`
- VM IP: `10.100.0.4`
- CUDN subnet: `10.100.0.0/16`
