#!/bin/bash

set -x

# Store the AWS account ID in a variable
aws_account_id=$(aws sts get-caller-identity --query 'Account' --output text)

# Print the AWS account ID
echo "AWS Account ID: $aws_account_id"

# Set AWS region, bucket name, and other variables
aws_region="us-east-1"
bucket_name="ekangaki-ultimate-bucket"
lambda_func_name="s3-lambda-function"
role_name="s3-lambda-sns"
email_address="georgegedeon2012@gmail.com"
lambda_zip_file="s3-lambda-function.zip"

# Ensure zip is installed
if ! command -v zip &> /dev/null; then
    echo "zip command not found. Installing..."
    sudo apt update && sudo apt install -y zip
fi

# Create IAM Role
role_response=$(aws iam create-role --role-name "$role_name" --assume-role-policy-document '{
  "Version": "2012-10-17",
  "Statement": [{
    "Action": "sts:AssumeRole",
    "Effect": "Allow",
    "Principal": {
      "Service": [
         "lambda.amazonaws.com",
         "s3.amazonaws.com",
         "sns.amazonaws.com"
      ]
    }
  }]
}')

# Extract and print Role ARN
role_arn=$(echo "$role_response" | jq -r '.Role.Arn')
echo "Role ARN: $role_arn"

# Attach policies to the role
aws iam attach-role-policy --role-name "$role_name" --policy-arn arn:aws:iam::aws:policy/AWSLambda_FullAccess
aws iam attach-role-policy --role-name "$role_name" --policy-arn arn:aws:iam::aws:policy/AmazonSNSFullAccess

# Create S3 bucket if it does not exist
if aws s3api head-bucket --bucket "$bucket_name" 2>/dev/null; then
    echo "Bucket $bucket_name already exists."
else
    aws s3api create-bucket --bucket "$bucket_name" --region "$aws_region" --create-bucket-configuration LocationConstraint="$aws_region"
    echo "Bucket $bucket_name created."
fi

# Upload a test file to the bucket
echo "This is a sample file." > example_file.txt
aws s3 cp ./example_file.txt s3://"$bucket_name"/example_file.txt

# Create a sample Lambda function file
mkdir -p ./s3-lambda-function
echo 'def lambda_handler(event, context):
    print("Event: ", event)
    return {"statusCode": 200, "body": "Hello from Lambda"}' > ./s3-lambda-function/lambda_function.py

# Zip the Lambda function
zip -r "$lambda_zip_file" ./s3-lambda-function

# Wait for role propagation
sleep 10

# Create Lambda function
aws lambda create-function \
  --region "$aws_region" \
  --function-name "$lambda_func_name" \
  --runtime "python3.8" \
  --handler "lambda_function.lambda_handler" \
  --memory-size 128 \
  --timeout 30 \
  --role "$role_arn" \
  --zip-file "fileb://$lambda_zip_file"

# Add permissions to Lambda for S3 bucket invocation
aws lambda add-permission \
  --function-name "$lambda_func_name" \
  --statement-id "s3-lambda-sns" \
  --action "lambda:InvokeFunction" \
  --principal s3.amazonaws.com \
  --source-arn "arn:aws:s3:::$bucket_name"

# Configure S3 bucket notification for Lambda
LambdaFunctionArn="arn:aws:lambda:$aws_region:$aws_account_id:function:$lambda_func_name"
aws s3api put-bucket-notification-configuration \
  --region "$aws_region" \
  --bucket "$bucket_name" \
  --notification-configuration '{
    "LambdaFunctionConfigurations": [{
        "LambdaFunctionArn": "'"$LambdaFunctionArn"'",
        "Events": ["s3:ObjectCreated:*"]
    }]
}'

# Create an SNS topic and subscribe
topic_arn=$(aws sns create-topic --name "$role_name" --output json | jq -r '.TopicArn')
echo "SNS Topic ARN: $topic_arn"

aws sns subscribe \
  --topic-arn "$topic_arn" \
  --protocol email \
  --notification-endpoint "$email_address"

# Publish test message to SNS topic
aws sns publish \
  --topic-arn "$topic_arn" \
  --subject "A new object created in s3 bucket" \
  --message "Hello from your automated AWS Lambda & S3 integration script!"

echo "Script execution completed."


