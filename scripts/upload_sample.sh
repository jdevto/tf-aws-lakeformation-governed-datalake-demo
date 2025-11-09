#!/bin/bash
# Upload sample Parquet data to S3

set -e

# Get bucket name from Terraform output or use variable
BUCKET_NAME="${1:-$(terraform output -raw lake_bucket_name 2>/dev/null || echo '')}"

if [ -z "$BUCKET_NAME" ]; then
  echo "Error: Bucket name not provided and not found in Terraform output"
  echo "Usage: $0 <bucket-name>"
  echo "Or run: terraform output lake_bucket_name"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DATA_FILE="$PROJECT_ROOT/data/sales_sample.parquet"

if [ ! -f "$DATA_FILE" ]; then
  echo "Error: Sample data file not found: $DATA_FILE"
  echo "Please generate it first using: python scripts/generate_sample_data.py"
  exit 1
fi

echo "Uploading sample data to s3://$BUCKET_NAME/sales/..."
aws s3 cp "$DATA_FILE" "s3://$BUCKET_NAME/sales/sales_sample.parquet"

echo "Sample data uploaded successfully!"
echo "Data location: s3://$BUCKET_NAME/sales/sales_sample.parquet"
