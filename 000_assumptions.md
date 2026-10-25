# Assumptions

```
VPC Addressing: Provider A VPC operates on a non-overlapping private CIDR block. Bare-metal nodes do not overlap with this CIDR. (172.29.0.0/16 in mock, 10.0.0.0/16 in production). Bare-metal nodes do not overlap with this CIDR.

Fixed Cloud Constraints: Provider A's Kubernetes cluster and SaaS services are strictly single-zone; no cloud-provider interconnect or direct peering is purchasable or permitted.

Small SRE Team: An operations team of 3 engineers manages this setup alongside standard duties; So, no solutions requiring heavy distributed state.

Transport: Internet transit between Provider A and B supports standard UDP traffic. MTU over internet transit defaults to ~1500 bytes.

```
