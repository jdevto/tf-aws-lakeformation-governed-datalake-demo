# AWS Lake Formation Governed Data Lake Demo

A Terraform demonstration of AWS Lake Formation capabilities including row-level security, column masking, and fine-grained access control.

## Overview

This demo creates a minimal governed data lake that demonstrates:

- **Row-level security**: Data Cells Filters restrict Analyst role to APAC region only
- **Column masking**: PII columns (email, SSN) are tagged and excluded from Analyst access
- **Masked views**: Athena view with SQL-based masking for Analyst access
- **Audit logging**: Lake Formation audit logging enabled

## Architecture

```plaintext
┌─────────────────────────────────────────────────────────┐
│                    S3 Data Lake                         │
│  ┌──────────────────────────────────────────────────┐   │
│  │  sales/ (Parquet files)                        │   │
│  └──────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────┐
│              AWS Glue Data Catalog                      │
│  ┌──────────────────────────────────────────────────┐   │
│  │  sales_db.sales (External Table)                  │   │
│  │  - customer_email (PII tagged)                   │   │
│  │  - ssn (PII tagged)                               │   │
│  └──────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────┐
│            Lake Formation Governance                     │
│  ┌──────────────────────────────────────────────────┐   │
│  │  Data Cells Filter: analyst-apac-filter           │   │
│  │  - Row filter: sales_region = 'APAC'             │   │
│  │  - Column filter: exclude PII columns            │   │
│  └──────────────────────────────────────────────────┘   │
│  ┌──────────────────────────────────────────────────┐   │
│  │  Grants:                                         │   │
│  │  - DataAdmin: ALL on base table                  │   │
│  │  - Analyst: SELECT via filter only              │   │
│  └──────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────┐
│                  Athena                                  │
│  ┌──────────────────────────────────────────────────┐   │
│  │  sales_masked (View with masked PII)              │   │
│  │  - Analyst: SELECT on view                        │   │
│  └──────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

## Prerequisites

- AWS CLI configured with appropriate credentials
- Terraform >= 1.0
- Python 3.x with pandas and pyarrow (for sample data generation)
- AWS account with permissions to create:
  - S3 buckets
  - IAM roles and policies
  - Glue databases and tables
  - Lake Formation resources (requires Lake Formation admin permissions)
  - Athena workgroups

**Important**: The AWS user/role running Terraform must be a Lake Formation admin to create tags and manage permissions.

**To fix "Insufficient Lake Formation permission(s)" error:**

Before running `terraform apply`, add yourself as a Lake Formation admin:

```bash
# 1. Get your current AWS user/role ARN
aws sts get-caller-identity --query Arn --output text

# 2. Add yourself as a Lake Formation admin (replace YOUR-ARN with the output above)
aws lakeformation put-data-lake-settings \
  --data-lake-settings Admins=YOUR-ARN

# Or if you have multiple admins already:
aws lakeformation get-data-lake-settings --query 'DataLakeSettings.Admins' --output text
# Then add your ARN to the existing list
```

Alternatively, if you're an IAM admin, you can grant yourself Lake Formation permissions via IAM policy.

## Quick Start

### 1. Configure Variables (Optional)

Create `terraform.tfvars` if you want to customize values:

```hcl
# terraform.tfvars
enable_lakeformation_governance = true  # Set to true if you have Lake Formation admin permissions
tags = {
  Project     = "MyProject"
  Environment = "Demo"
}
```

**Important**: Set `enable_lakeformation_governance = true` only if you have Lake Formation admin permissions. If set to `false`, the demo will deploy without governance features (tags, filters, grants).

### 2. Generate Sample Data

Generate the sample Parquet file:

```bash
# Install dependencies if needed
pip install pandas pyarrow

# Generate sample data
python3 scripts/generate_sample_data.py
```

This creates `data/sales_sample.parquet` with:

- 20 sales records
- Multiple regions (APAC, EMEA, AMER)
- PII columns (customer_email, ssn)

### 3. Deploy Infrastructure

Initialize and apply Terraform:

```bash
terraform init
terraform plan
terraform apply
```

**Note**: The setup should complete in a single apply. All resources are created together.

### 4. Upload Sample Data

Upload the sample data to S3:

```bash
# Get bucket name from Terraform output
BUCKET=$(terraform output -raw lake_bucket_name)
# Output: lakeformation-demo-lake-<random-suffix>

# Upload the sample data
aws s3 cp data/sales_sample.parquet s3://$BUCKET/sales/
# Output: upload: data/sales_sample.parquet to s3://<bucket>/sales/sales_sample.parquet
```

Or use the upload script:

```bash
./scripts/upload_sample.sh
```

### 5. Create Athena View

Create the masked view using the SQL from Terraform outputs:

```bash
terraform output create_view_sql
```

Copy the SQL and run it in the Athena console, or use AWS CLI:

```bash
# Get values from Terraform outputs
WORKGROUP=$(terraform output -raw athena_workgroup_name 2>/dev/null || echo "lakeformation-demo-workgroup")
QUERY_BUCKET=$(terraform output -raw query_results_bucket_name)
VIEW_SQL=$(terraform output -raw create_view_sql | sed 's/^"//;s/"$//')
REGION=$(aws configure get region 2>/dev/null || echo "ap-southeast-2")

# Verify workgroup exists (specify region explicitly)
if ! aws athena get-work-group --work-group "$WORKGROUP" --region "$REGION" &>/dev/null; then
  echo "Error: Workgroup '$WORKGROUP' not found in region $REGION. Ensure 'terraform apply' completed successfully."
fi

# Create the view
QUERY_ID=$(aws athena start-query-execution \
  --query-string "$VIEW_SQL" \
  --work-group "$WORKGROUP" \
  --region "$REGION" \
  --result-configuration "OutputLocation=s3://$QUERY_BUCKET/athena-results/" \
  --query 'QueryExecutionId' --output text)

echo "View creation started. Query ID: $QUERY_ID"
echo "Check status with: aws athena get-query-execution --query-execution-id $QUERY_ID --region $REGION"
```

After the view is created, apply Terraform again to grant Analyst access:

```bash
terraform apply
```

### 6. Validate Setup

Run the validation script to test the setup:

```bash
./scripts/validate.sh
```

**Output locations:**

- **Terminal**: Query results are displayed as tables in the console after each query completes
- **S3**: Detailed query results (CSV files) are saved to the query results bucket:

  ```bash
  # View query results in S3
  BUCKET=$(terraform output -raw query_results_bucket_name)
  aws s3 ls s3://$BUCKET/validation-results/
  ```

This script will:

- Run queries as DataAdmin (should see all rows and PII)
- Run queries as Analyst (should see only APAC rows, no PII)
- Run queries on masked view (should see masked PII)

## Manual Validation

You can also validate manually using the queries from Terraform outputs:

```bash
# Get validation queries
terraform output validation_queries

# Assume DataAdmin role and run queries
aws sts assume-role --role-arn $(terraform output -raw dataadmin_role_arn) --role-session-name test

# Assume Analyst role and run queries
aws sts assume-role --role-arn $(terraform output -raw analyst_role_arn) --role-session-name test
```

### Expected Results

**As DataAdmin:**

- Can see all regions (APAC, EMEA, AMER)
- Can see all columns including PII (customer_email, ssn)
- Can query base table directly

**As Analyst:**

- Can see only APAC region rows
- Cannot see PII columns (customer_email, ssn) from base table
- Can query masked view and see masked PII (email: `***@`, SSN: `***-**-****`)

## Resource Details

### S3 Buckets

- **Data Lake Bucket**: Stores Parquet data files
  - Encryption: SSE-S3
  - Versioning: Enabled
  - Public access: Blocked

- **Query Results Bucket**: Stores Athena query results
  - Encryption: SSE-S3
  - Public access: Blocked

### IAM Roles

- **DataAdmin**: Full access to all resources
- **Analyst**: Restricted access via Lake Formation filters

### Glue Catalog

- **Database**: `sales_db`
- **Table**: `sales` (external table pointing to S3)
- **Columns**:
  - `customer_id` (string)
  - `customer_name` (string)
  - `customer_email` (string) - PII tagged
  - `ssn` (string) - PII tagged
  - `sales_region` (string)
  - `sales_amount` (double)
  - `sale_date` (string)

### Lake Formation

- **Tag**: `pii` with values `sensitive`, `clear`
- **Column Tags**: `customer_email` and `ssn` tagged as `pii=sensitive`
- **Data Cells Filter**: `analyst-apac-filter` (only if `enable_lakeformation_governance = true`)
  - Row filter: `sales_region = 'APAC'`
  - Column filter: Excludes PII columns
- **Grants** (only if `enable_lakeformation_governance = true`):
  - DataAdmin: ALL on base table
  - Analyst: SELECT via data cells filter
  - Analyst: SELECT on masked view (after view is created)

### Athena

- **Workgroup**: `lakeformation-demo-workgroup`
- **View**: `sales_masked` (created via SQL)
  - Masks email: `REGEXP_REPLACE(customer_email, '^([^@]{1,3}).*@', '***@')`
  - Masks SSN: `REGEXP_REPLACE(ssn, '\\d', '*')`

## Guardrails

All resources include:

- ✅ S3 encryption at rest (SSE-S3)
- ✅ S3 public access blocking
- ✅ Athena query result encryption
- ✅ Lake Formation audit logging
- ✅ IAM least privilege policies
- ✅ Resource tagging for cost tracking

## Cleanup

To destroy all resources:

```bash
# 1. Delete Athena view (if created)
# Run in Athena console: DROP VIEW sales_db.sales_masked;

# 2. Empty S3 buckets (optional - buckets have force_destroy enabled)
BUCKET=$(terraform output -raw lake_bucket_name)
QUERY_BUCKET=$(terraform output -raw query_results_bucket_name)
aws s3 rm s3://$BUCKET --recursive
aws s3 rm s3://$QUERY_BUCKET --recursive

# 3. Destroy Terraform resources
terraform destroy
```

**Automatic Cleanup**: The Terraform configuration includes destroy-time provisioners that automatically:

- Delete Athena workgroup with `--recursive-delete-option` to handle query executions
- Attempt to delete Lake Formation service-linked role before deregistering S3 location

If cleanup fails, you may need to manually delete:

- Athena workgroup (if it still contains query executions after 45-day retention)
- Lake Formation service-linked role: `AWSServiceRoleForLakeFormationDataAccess` (if it's the last S3 location)

## Troubleshooting

### Terraform Linter Warnings

If you see linter warnings about Lake Formation resources (e.g., "Unexpected block" or "Unexpected attribute"), these may be false positives. The code is written for AWS Provider >= 6.0. If you encounter actual Terraform apply errors, you may need to:

- Update to the latest AWS provider version: `terraform init -upgrade`
- Check the [AWS Provider documentation](https://registry.terraform.io/providers/hashicorp/aws/latest/docs) for the latest resource schemas

### "Access Denied" errors

- Ensure IAM roles have proper trust relationships
- Check Lake Formation grants are applied correctly
- Verify S3 bucket policies allow access
- Ensure you're using the correct role when assuming roles

### View creation fails

- Ensure base table exists and has data
- Check Athena workgroup permissions
- Verify SQL syntax is correct
- Ensure the view is created before applying the Analyst view grant

### Validation script fails

- Ensure AWS CLI is configured
- Check that roles can be assumed
- Verify Athena queries complete successfully
- Install Python dependencies: `pip install pandas pyarrow` (for sample data generation)

### Sample data generation fails

Install required Python packages:

```bash
pip install pandas pyarrow
```

Or use a virtual environment:

```bash
python3 -m venv venv
source venv/bin/activate  # On Windows: venv\Scripts\activate
pip install pandas pyarrow
python scripts/generate_sample_data.py
```

## Sample Data Schema

The sample Parquet file contains:

- **20 records** across 3 regions:
  - APAC: 9 records
  - EMEA: 6 records
  - AMER: 5 records

- **Columns**:
  - `customer_id`: Unique customer identifier
  - `customer_name`: Customer name
  - `customer_email`: Email address (PII)
  - `ssn`: Social Security Number (PII)
  - `sales_region`: Region code (APAC, EMEA, AMER)
  - `sales_amount`: Sales amount (double)
  - `sale_date`: Sale date (YYYY-MM-DD)

## Outputs

Key outputs from Terraform:

- `lake_bucket_name`: S3 bucket for data lake
- `query_results_bucket_name`: S3 bucket for Athena results
- `dataadmin_role_arn`: DataAdmin IAM role ARN
- `analyst_role_arn`: Analyst IAM role ARN
- `database_name`: Glue database name
- `table_name`: Glue table name
- `view_name`: Athena view name
- `create_view_sql`: SQL to create the masked view
- `validation_queries`: Test queries for validation

## License

See LICENSE file for details.

## Contributing

This is a demo project. For production use, consider:

- Using modules for reusability
- Adding more comprehensive error handling
- Implementing automated testing
- Adding monitoring and alerting
- Using KMS for encryption instead of SSE-S3
- Implementing backup and disaster recovery
