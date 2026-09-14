#!/usr/bin/env bash
#
# Creates the VPC prerequisites for running the agent with networkMode=VPC.
#
# Builds: VPC -> IGW -> 1 public subnet (NAT) -> 2 private subnets in
# AgentCore-supported AZs -> NAT gateway -> route tables -> 2 security groups
# -> VPC endpoints (ecr.api, ecr.dkr, logs, s3 gateway, optionally
# bedrock-runtime).
#
# COST WARNING: the NAT gateway bills roughly $0.045/hour (~$32/month) plus
# data processing for as long as it exists.  Set CREATE_NAT=false if the agent
# needs no internet egress -- see the note on the model provider in DEPLOY.md.
#
# Prints the subnet and security group ids to append to config.env.
set -euo pipefail
cd "$(dirname "$0")"
source ./config.env
source ./supported-azs.env

VPC_CIDR="${VPC_CIDR:-10.0.0.0/16}"
CREATE_NAT="${CREATE_NAT:-true}"
# Set to true once a Bedrock model provider is in use, to keep model traffic
# off the internet entirely.
CREATE_BEDROCK_ENDPOINT="${CREATE_BEDROCK_ENDPOINT:-false}"
TAG="agentcore-${AGENT_NAME}"

AZ_IDS="${AGENTCORE_AZ_IDS[$AWS_REGION]:-}"
if [ -z "${AZ_IDS}" ]; then
  echo "AgentCore VPC mode is not documented as available in ${AWS_REGION}." >&2
  exit 1
fi
read -r AZ_ID_A AZ_ID_B _ <<<"${AZ_IDS}"
: "${AZ_ID_B:=${AZ_ID_A}}"

tag() { aws ec2 create-tags --region "${AWS_REGION}" --resources "$1" \
          --tags "Key=Name,Value=$2" "Key=ManagedBy,Value=${TAG}"; }

az_name() {  # AZ id -> AZ name in this account
  aws ec2 describe-availability-zones --region "${AWS_REGION}" \
    --filters "Name=zone-id,Values=$1" --query 'AvailabilityZones[0].ZoneName' --output text
}

echo "Region ${AWS_REGION}; using AZs ${AZ_ID_A} and ${AZ_ID_B}"
AZ_A=$(az_name "${AZ_ID_A}"); AZ_B=$(az_name "${AZ_ID_B}")

# --- VPC -------------------------------------------------------------------
VPC_ID=$(aws ec2 create-vpc --region "${AWS_REGION}" --cidr-block "${VPC_CIDR}" \
  --query Vpc.VpcId --output text)
tag "${VPC_ID}" "${TAG}-vpc"
# Both must be on, or endpoint and EFS DNS names will not resolve.
aws ec2 modify-vpc-attribute --region "${AWS_REGION}" --vpc-id "${VPC_ID}" --enable-dns-support
aws ec2 modify-vpc-attribute --region "${AWS_REGION}" --vpc-id "${VPC_ID}" --enable-dns-hostnames
echo "VPC ${VPC_ID}"

# --- Subnets ---------------------------------------------------------------
mk_subnet() {  # cidr, az, name
  local id
  id=$(aws ec2 create-subnet --region "${AWS_REGION}" --vpc-id "${VPC_ID}" \
        --cidr-block "$1" --availability-zone "$2" --query Subnet.SubnetId --output text)
  tag "${id}" "$3"
  echo "${id}"
}
PUBLIC_SUBNET=$(mk_subnet 10.0.0.0/24  "${AZ_A}" "${TAG}-public-a")
PRIVATE_SUBNET_A=$(mk_subnet 10.0.10.0/24 "${AZ_A}" "${TAG}-private-a")
PRIVATE_SUBNET_B=$(mk_subnet 10.0.11.0/24 "${AZ_B}" "${TAG}-private-b")
echo "Subnets: public ${PUBLIC_SUBNET}; private ${PRIVATE_SUBNET_A} ${PRIVATE_SUBNET_B}"

# --- Internet gateway + public route table ---------------------------------
IGW_ID=$(aws ec2 create-internet-gateway --region "${AWS_REGION}" \
  --query InternetGateway.InternetGatewayId --output text)
tag "${IGW_ID}" "${TAG}-igw"
aws ec2 attach-internet-gateway --region "${AWS_REGION}" \
  --internet-gateway-id "${IGW_ID}" --vpc-id "${VPC_ID}"

PUBLIC_RT=$(aws ec2 create-route-table --region "${AWS_REGION}" --vpc-id "${VPC_ID}" \
  --query RouteTable.RouteTableId --output text)
tag "${PUBLIC_RT}" "${TAG}-rt-public"
aws ec2 create-route --region "${AWS_REGION}" --route-table-id "${PUBLIC_RT}" \
  --destination-cidr-block 0.0.0.0/0 --gateway-id "${IGW_ID}" >/dev/null
aws ec2 associate-route-table --region "${AWS_REGION}" \
  --route-table-id "${PUBLIC_RT}" --subnet-id "${PUBLIC_SUBNET}" >/dev/null

# --- Private route table (+ NAT) -------------------------------------------
PRIVATE_RT=$(aws ec2 create-route-table --region "${AWS_REGION}" --vpc-id "${VPC_ID}" \
  --query RouteTable.RouteTableId --output text)
tag "${PRIVATE_RT}" "${TAG}-rt-private"
for s in "${PRIVATE_SUBNET_A}" "${PRIVATE_SUBNET_B}"; do
  aws ec2 associate-route-table --region "${AWS_REGION}" \
    --route-table-id "${PRIVATE_RT}" --subnet-id "${s}" >/dev/null
done

if [ "${CREATE_NAT}" = "true" ]; then
  echo "Creating NAT gateway (billed hourly until deleted)..."
  EIP_ALLOC=$(aws ec2 allocate-address --region "${AWS_REGION}" --domain vpc \
    --query AllocationId --output text)
  NAT_ID=$(aws ec2 create-nat-gateway --region "${AWS_REGION}" \
    --subnet-id "${PUBLIC_SUBNET}" --allocation-id "${EIP_ALLOC}" \
    --query NatGateway.NatGatewayId --output text)
  tag "${NAT_ID}" "${TAG}-nat"
  aws ec2 wait nat-gateway-available --region "${AWS_REGION}" --nat-gateway-ids "${NAT_ID}"
  aws ec2 create-route --region "${AWS_REGION}" --route-table-id "${PRIVATE_RT}" \
    --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "${NAT_ID}" >/dev/null
  echo "NAT ${NAT_ID}"
fi

# --- Security groups -------------------------------------------------------
# The runtime ENIs only ever initiate connections, so they need no ingress.
AGENT_SG=$(aws ec2 create-security-group --region "${AWS_REGION}" --vpc-id "${VPC_ID}" \
  --group-name "${TAG}-agent" --description "AgentCore runtime ENIs" \
  --query GroupId --output text)
tag "${AGENT_SG}" "${TAG}-agent"

# Interface endpoints need 443 inbound from the runtime.
ENDPOINT_SG=$(aws ec2 create-security-group --region "${AWS_REGION}" --vpc-id "${VPC_ID}" \
  --group-name "${TAG}-endpoints" --description "Interface VPC endpoints" \
  --query GroupId --output text)
tag "${ENDPOINT_SG}" "${TAG}-endpoints"
aws ec2 authorize-security-group-ingress --region "${AWS_REGION}" \
  --group-id "${ENDPOINT_SG}" --protocol tcp --port 443 --source-group "${AGENT_SG}" >/dev/null

# --- VPC endpoints ---------------------------------------------------------
# Required when the VPC has no internet path; recommended regardless, since
# they avoid NAT data-processing charges.
mk_interface_endpoint() {
  local svc="$1"
  local id
  id=$(aws ec2 create-vpc-endpoint --region "${AWS_REGION}" --vpc-id "${VPC_ID}" \
    --vpc-endpoint-type Interface \
    --service-name "com.amazonaws.${AWS_REGION}.${svc}" \
    --subnet-ids "${PRIVATE_SUBNET_A}" "${PRIVATE_SUBNET_B}" \
    --security-group-ids "${ENDPOINT_SG}" \
    --private-dns-enabled \
    --query VpcEndpoint.VpcEndpointId --output text)
  tag "${id}" "${TAG}-vpce-${svc}"
  echo "  ${svc} -> ${id}"
}

echo "Creating VPC endpoints..."
mk_interface_endpoint ecr.api
mk_interface_endpoint ecr.dkr
mk_interface_endpoint logs
if [ "${CREATE_BEDROCK_ENDPOINT}" = "true" ]; then
  mk_interface_endpoint bedrock-runtime
fi

# S3 must be a *gateway* endpoint: AgentCore periodically re-pulls the image
# from ECR, whose layers live in S3.  Since the May 2026 rollout AgentCore no
# longer provisions a service-managed S3 gateway, so this one is on us.
S3_VPCE=$(aws ec2 create-vpc-endpoint --region "${AWS_REGION}" --vpc-id "${VPC_ID}" \
  --vpc-endpoint-type Gateway \
  --service-name "com.amazonaws.${AWS_REGION}.s3" \
  --route-table-ids "${PRIVATE_RT}" \
  --policy-document "$(sed "s/{{REGION}}/${AWS_REGION}/g" s3-endpoint-policy.json)" \
  --query VpcEndpoint.VpcEndpointId --output text)
tag "${S3_VPCE}" "${TAG}-vpce-s3"
echo "  s3 (gateway) -> ${S3_VPCE}"

cat <<SUMMARY

Done. Append to config.env:

  export NETWORK_MODE="VPC"
  export AGENT_SUBNETS="${PRIVATE_SUBNET_A},${PRIVATE_SUBNET_B}"
  export AGENT_SECURITY_GROUPS="${AGENT_SG}"

Then re-run ./03-deploy-runtime.sh.

To tear down later, delete in this order: agent runtime, VPC endpoints,
NAT gateway, release the Elastic IP, subnets, route tables, IGW (detach
first), security groups, VPC.
SUMMARY
