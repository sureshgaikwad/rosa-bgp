#!/bin/bash

oc patch Network.operator.openshift.io cluster --type=merge -p='{"spec":{"additionalRoutingCapabilities": {"providers": ["FRR"]}, "defaultNetwork":{"ovnKubernetesConfig":{"routeAdvertisements":"Enabled"}}}}'
echo "waiting 60s for openshift-frr-k8s namespace to become available"
sleep 60

cat << EOF | oc apply -f -
apiVersion: frrk8s.metallb.io/v1beta1
kind: FRRConfiguration
metadata:
  name: all-nodes
  namespace: openshift-frr-k8s
spec:
  nodeSelector:
    matchLabels:
      bgp_router: "true"
  bgp:
    routers:
    - asn: `echo $(terraform output -raw rosa_bgp_asn)`
      neighbors:
      - address: `echo $(terraform output -raw vpc1-rs1-subnet1-ep1_ip)`
        asn: `echo $(terraform output -raw vpc1-rs1-asn)`
        disableMP: true
        toReceive:
          allowed:
            mode: all
      - address: `echo $(terraform output -raw vpc1-rs1-subnet1-ep2_ip)`
        asn: `echo $(terraform output -raw vpc1-rs1-asn)`
        disableMP: true
        toReceive:
          allowed:
            mode: all
      - address: `echo $(terraform output -raw vpc1-rs1-subnet2-ep1_ip)`
        asn: `echo $(terraform output -raw vpc1-rs1-asn)`
        disableMP: true
        toReceive:
          allowed:
            mode: all
      - address: `echo $(terraform output -raw vpc1-rs1-subnet2-ep2_ip)`
        asn: `echo $(terraform output -raw vpc1-rs1-asn)`
        disableMP: true
        toReceive:
          allowed:
            mode: all
      - address: `echo $(terraform output -raw vpc1-rs1-subnet3-ep1_ip)`
        asn: `echo $(terraform output -raw vpc1-rs1-asn)`
        disableMP: true
        toReceive:
          allowed:
            mode: all
      - address: `echo $(terraform output -raw vpc1-rs1-subnet3-ep2_ip)`
        asn: `echo $(terraform output -raw vpc1-rs1-asn)`
        disableMP: true
        toReceive:
          allowed:
            mode: all
EOF
