#!/bin/bash
# save as: get-import-ids.sh
# login and export profile before running

VPC_ID="vpc-0ee0d1b8a2c83120e"  # Get this from Console first

echo "=== VPC ==="
aws ec2 describe-vpcs --vpc-ids $VPC_ID \
  --query 'Vpcs[0].[VpcId,CidrBlock]' --output table

echo "=== Subnets ==="
aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[].[Tags[?Key==`Name`].Value|[0],SubnetId,CidrBlock,AvailabilityZone]' \
  --output table

echo "=== Internet Gateway ==="
aws ec2 describe-internet-gateways \
  --filters "Name=attachment.vpc-id,Values=$VPC_ID" --output table

echo "=== NAT Gateways ==="
aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" --output table

echo "=== Route Tables ==="
aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" --output table

