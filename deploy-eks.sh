#!/bin/bash

# --- Configuration ---

STACK_NAME="CustomVPC"

# The local filename of your EKS cluster template.
TEMPLATE_FILE="EKS_Cluster.yaml"

# --- Deployment Command ---
echo "Starting EKS cluster deployment for stack: $STACK_NAME..."

aws cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --template-file "$TEMPLATE_FILE" \
  --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
  --parameter-overrides VPCStackName="$STACK_NAME"

# Check the exit code of the deploy command
if [ $? -eq 0 ]; then
  echo "Deployment command sent successfully. Check the AWS CloudFormation console for progress."
else
  echo " Deployment command failed. Please check the error message above."
fi

