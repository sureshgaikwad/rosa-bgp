* Connectivity - for each test case, verify the following work from source to destination: ping, curl
    * VM with primary CUDN - Uses a VM in CUDN A, and a second VM in CUDN B
        * CUDN VM A/B traffic to Internet - expected to succeed - PASS
        * EC2 instance in same VPC to CUDN A/B VM - expected to succeed - PASS
        * EC2 instance in external VPC to transit gateway to CUDN VM A/B - expected to succeed - PASS
        * CUDN VM A/B to EC2 instance in same VPC - expected to succeed - PASS
        * CUDN VM A/B to transit gateway to EC2 instance in external VPC - expected to succeed - PASS
        * CUDN VM A/B to kapi - expected to succeed - PASS
            * Public API hostname tested: `api.ds-bgp.0w32.p3.openshiftapps.com`
            * Kubernetes service ClusterIP tested: `172.30.0.1`
            * `ping` to the public API hostname and Kubernetes service ClusterIP failed
            * TCP/HTTPS connectivity to kapi succeeded
            * `/version` and `/readyz` returned 200
            * `GET /` returned 403 as `system:anonymous`, which is expected for unauthenticated access
        * CUDN VM A/B to kube dns - expected to succeed - PARTIAL
            * VM DNS server is `172.30.0.10`
            * reachability to DNS server:
                * `ping 172.30.0.10` - FAIL
                * `nc -vz 172.30.0.10 53` - PASS
            * name resolution:
                * `api.ds-bgp.0w32.p3.openshiftapps.com` - PASS
                * `kubernetes.default.svc.cluster.local` - FAIL from VM
                    * Note: only this one cluster-internal service name was tested; this does not prove all cluster-internal names fail
                    * Note: QE was able to nslookup kubernetes.default.svc.cluster.local from within a pod in a CUDN, so this may be specific to VMs.
        * CUDN VM A/B to port on worker node host API service
            * Here is what was tested before with pods, by way of explanation
              ```
oc get ep -n default
Warning: v1 Endpoints is deprecated in v1.33+; use discovery.k8s.io/v1 EndpointSlice
NAME         ENDPOINTS                                         AGE
kubernetes   10.0.57.255:6443,10.0.58.57:6443,10.0.63.0:6443   27h

% oc rsh -n test hello-pod
~ $ curl  10.0.57.255:6443 -k
Client sent an HTTP request to an HTTPS server.
~ $ curl  10.0.57.255:6443 -k -v
*   Trying 10.0.57.255:6443...
* Connected to 10.0.57.255 (10.0.57.255) port 6443 (#0)
> GET / HTTP/1.1
> Host: 10.0.57.255:6443
> User-Agent: curl/7.79.1
> Accept: */*
> 
* Mark bundle as not supporting multiuse
* HTTP 1.0, assume close after body
< HTTP/1.0 400 Bad Request
< 
Client sent an HTTP request to an HTTPS server.
            ```
        * CUDN A VM to CUDN A VM (on the same node) - expected to succeed
        * CUDN A VM to CUDN A VM (on a different node) - expected to succeed - PASS
        * CUDN A VM to CUDN A VM (different node) - expected to succeed - PASS
            * vm0: 10.100.0.10 on ip-10-0-1-238.ca-central-1.compute.internal
            * vm1: 10.100.0.11 on ip-10-0-2-18.ca-central-1.compute.internal
            * ping: PASS
            * nc 8081: PASS
            * curl http://10.100.0.11:8081: PASS (HTTP 200 OK)
        * CUDN A VM to CUDN B VM (on the same node) - expected to not succeed - PASS
            * This was with advertised-udn-isolation-mode set to strict, the default. It's possible there would be a different result if it were set to loose.
        * CUDN A VM to CUDN B VM (on a different node) - expected to not succeed - PASS- expected to succeed
        * Worker node (via `oc debug node`) same host to CUDN A/B VM - expected to not succeed - PASS
            * UDNs are expected to isolate networking even on the same host
        * Worker node (via `oc debug node`) diff host to CUDN A/B VM - expected to not succeed - PASS
        * CUDN A VM traffic in and out to VPC continue to work after VM is live-migrated - expected to succeed - FAIL
            * Observed issue where after live migration, pings from EC2 in same VPC to VM were flappy, with periods of connectivity and periods where all packets were dropped. It is possible that this is actually a result of setting the `allow-pod-bridge-network-live-migration` annotation, which should not have been necessary but without it the VM was not live-migratable at all. See [reproducer](connectivity-reproducer.md) and [Claude Code's writeup of its troubleshooting of the problem](live-migration-connectivity-issue.md) the latter of which may be helpful or complete nonsense.
    * ClusterIP Service with same L2 network
        * CUDN VM to clusterIP(internalTrafficPolicy=Cluster) with same node - expected to succeed - PASS
        * CUDN VM to clusterIP(internalTrafficPolicy=Cluster) with diff node - expected to succeed - PASS
        * CUDN VM to clusterIP(internalTrafficPolicy=Local) with same node - expected to succeed - FAIL
            * Possibly covered by https://redhat.atlassian.net/browse/OCPBUGS-59693
            * This has also worked for QE in the past with pods, so may be specific to VMs.
        * CUDN VM to clusterIP(internalTrafficPolicy=Local) with diff node - expected to not succeed - PASS
    * NodePort Service with same L2 network
        * CUDN VM to NodePort(ETP=Cluster) with same node - expected to succeed
        * CUDN VM to NodePort(ETP=Cluster) with diff node - expected to succeed
        * CUDN VM to NodePort(ETP=Local) with same node - expected to succeed
        * CUDN VM to NodePort(ETP=Local) with diff node (destionation with two backend pods/VMs, one is same as source VM, one is different) - expected to succeed
        * CUDN VM to NodePort(ETP=Local) with diff node (the source VM is different from any destinaton endpoints nodes) - expected to not succeed
    * NodePort service with different L2 network
        * CUDN VM to NodePort(ETP=Cluster) with same node - expected not to succeed
        * CUDN VM to NodePort(ETP=Cluster) with diff node - expected to succeed
        * CUDN VM to NodePort(ETP=Local) with same node - expected not to succeed
        * CUDN VM to NodePort(ETP=Local) with diff node (destination with two backend VMs, one is same as source VM, one is different) - expected to succeed
        * CUDN VM to NodePort(ETP=Local) with diff node (the source VM is different from any destinaton endpoints nodes) - expected not to succeed
* Connectivity through node lifecycle events
    * Failure of worker node that is the route next hop (simulate by forcing termination through EC2 console). Traffic should continue being passed.
        * CUDN VM to EC2 instance in same VPC - expected to succeed - PASS
            * No packet loss was observed when ping ran with default 1 second interval
        * CUDN VM to same VPC to transit gateway to EC2 instance in different VPC - expected to succeed - PASS
            * No packet loss was observed when ping ran with default 1 second interval
        * EC2 instance in same VPC to CUDN VM - expected to succeed - PASS
            * No packet loss was observed when ping ran with default 1 second interval
        * EC2 instance in different VPC to transit gateway to same VPC to CUDN VM - expected to succeed - PASS
            * No packet loss was observed when ping ran with default 1 second interval
    * MachinePool scaledown causes worker node that is the route next hop to be deleted
        * CUDN VM to EC2 instance in same VPC - expected to succeed
        * CUDN VM to same VPC to transit gateway to EC2 instance in different VPC - expected to succeed
        * EC2 instance in same VPC to CUDN VM - expected to succeed
        * EC2 instance in different VPC to transit gateway to same VPC to CUDN VM - expected to succeed
    * Version upgrade applied to MachinePool containing worker node that is the next route hop (causing worker node replacement and IP change)
        * CUDN VM to EC2 instance in same VPC - expected to succeed
        * CUDN VM to same VPC to transit gateway to EC2 instance in different VPC - expected to succeed
        * EC2 instance in same VPC to CUDN VM - expected to succeed
        * EC2 instance in different VPC to transit gateway to same VPC to CUDN VM - expected to succeed
* eni-srcdst-disable DaemonSet should configure new nodes to be traffic next hop
    * Connectivity from EC2 to CUDN VM and CUDN VM to EC2 after DaemonSet is instantiated on cluster that has not had `disable_src_dst_check.sh` run - expected to succeed - PASS
    * Connectivity from EC2 to CUDN VM and CUDN VM to EC2 should be maintained during all of the following scenarios
        * MachinePool scale up - expected to succeed - PASS
        * Cluster upgrade - expected to succeed - PARTIAL
            * Routes and peers were configured correctly. However, this depends upon live migration working correctly to fully pass.
* Route server peers during node lifecycle events
    * Route Server gets peers for new nodes - expected to succeed - PASS
    * Route server has old peers cleaned up when nodes go away - expected to succeed - PASS
