#!/bin/bash
# save as: get-import-ids.sh
# login and export profile before running

export VPC_ID="vpc-0ee0d1b8a2c83120e"  # Get this from Console first

echo "=== 1. VPC SETTINGS ==="
aws ec2 describe-vpcs --vpc-ids $VPC_ID \
  --query 'Vpcs[0].{ID:VpcId,CIDR:CidrBlock,Tenancy:InstanceTenancy}'

# DNS flags require separate attribute calls — describe-vpcs does not include them
echo "  DNS Support:"
aws ec2 describe-vpc-attribute --vpc-id $VPC_ID --attribute enableDnsSupport \
  --query 'EnableDnsSupport.Value'

echo "  DNS Hostnames:"
aws ec2 describe-vpc-attribute --vpc-id $VPC_ID --attribute enableDnsHostnames \
  --query 'EnableDnsHostnames.Value'

echo "=== 2. SUBNETS ==="
# AutoPublicIP=true means the subnet auto-assigns public IPs (Public subnet indicator)
# Cross-reference with §3 route tables to manually classify each subnet:
#   Public   = route table has 0.0.0.0/0 → igw-*
#   Private  = route table has 0.0.0.0/0 → nat-*
#   Isolated = route table has NO 0.0.0.0/0 route
aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[*].{ID:SubnetId,CIDR:CidrBlock,AZ:AvailabilityZone,AvailableIPs:AvailableIpAddressCount,AutoPublicIP:MapPublicIpOnLaunch}' \
  --output table

echo "=== 3. ROUTE TABLES (Public = 0.0.0.0/0->igw, Private = ->nat, Isolated = no default route) ==="
aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'RouteTables[*].{ID:RouteTableId,Subnets:Associations[*].SubnetId,Routes:Routes[*].{Dest:DestinationCidrBlock,Target:GatewayId||NatGatewayId}}' \
  --output json | jq .

echo "=== 4. NAT GATEWAYS ==="
aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" \
  --query 'NatGateways[*].{ID:NatGatewayId,State:State,Subnet:SubnetId,PublicIP:NatGatewayAddresses[0].PublicIp}' \
  --output table

echo "=== 5. INTERNET GATEWAYS ==="
aws ec2 describe-internet-gateways \
  --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
  --query 'InternetGateways[*].{ID:InternetGatewayId,State:Attachments[0].State}' \
  --output table

echo "=== 6. SECURITY GROUPS (attached to EC2 instances in this VPC) ==="
aws ec2 describe-instances --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Reservations[*].Instances[*].{InstanceId:InstanceId,Name:Tags[?Key==`Name`]|[0].Value,SGs:SecurityGroups[*].GroupId}' \
  --output table

echo "=== 7. RDS INSTANCES ==="
aws rds describe-db-instances \
  --query 'DBInstances[*].{ID:DBInstanceIdentifier,Engine:Engine,Port:Endpoint.Port,VPC:DBSubnetGroup.VpcId,SGs:VpcSecurityGroups[*].VpcSecurityGroupId}' \
  --output table

echo "=== 8. ELASTICACHE CLUSTERS ==="
aws elasticache describe-cache-clusters \
  --show-cache-node-info \
  --query 'CacheClusters[*].{ID:CacheClusterId,Engine:Engine,Version:EngineVersion,NodeType:CacheNodeType,Status:CacheClusterStatus,SubnetGroup:CacheSubnetGroupName,Endpoint:CacheNodes[0].Endpoint.Address,Port:CacheNodes[0].Endpoint.Port}' \
  --output table

echo "=== 8a. ELASTICACHE SUBNET GROUPS (shows VPC placement) ==="
aws elasticache describe-cache-subnet-groups \
  --query 'CacheSubnetGroups[*].{Name:CacheSubnetGroupName,VPC:VpcId,Subnets:Subnets[*].SubnetIdentifier}' \
  --output json | jq .