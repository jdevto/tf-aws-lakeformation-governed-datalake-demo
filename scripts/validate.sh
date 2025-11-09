#!/bin/bash
# Validation script to test Lake Formation row-level security and column masking

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get values from Terraform outputs
echo -e "${BLUE}Getting Terraform outputs...${NC}"
DATABASE_NAME=$(terraform output -raw database_name 2>/dev/null || echo 'sales_db')
TABLE_NAME=$(terraform output -raw table_name 2>/dev/null || echo 'sales')
VIEW_NAME=$(terraform output -raw view_name 2>/dev/null || echo 'sales_masked')
DATAADMIN_ROLE=$(terraform output -raw dataadmin_role_arn 2>/dev/null || echo '')
ANALYST_ROLE=$(terraform output -raw analyst_role_arn 2>/dev/null || echo '')
WORKGROUP=$(terraform output -raw athena_workgroup_name 2>/dev/null || echo 'lakeformation-demo-workgroup')
QUERY_RESULTS_BUCKET=$(terraform output -raw query_results_bucket_name 2>/dev/null || echo '')

if [ -z "$QUERY_RESULTS_BUCKET" ]; then
  echo -e "${RED}Error: Could not get query results bucket from Terraform output${NC}"
  exit 1
fi

echo -e "${GREEN}Configuration:${NC}"
echo "  Database: $DATABASE_NAME"
echo "  Table: $TABLE_NAME"
echo "  View: $VIEW_NAME"
echo "  Workgroup: $WORKGROUP"
echo ""

# Function to run Athena query
run_query() {
  local role_arn=$1
  local query=$2
  local description=$3

  echo -e "${YELLOW}Running query as ${role_arn##*/}...${NC}"
  echo -e "${BLUE}Description: $description${NC}"
  echo ""

  # Create temporary credentials
  CREDS=$(aws sts assume-role \
    --role-arn "$role_arn" \
    --role-session-name "validation-test-$(date +%s)" \
    --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
    --output text 2>/dev/null)

  if [ $? -ne 0 ]; then
    echo -e "${RED}Error: Could not assume role $role_arn${NC}"
    echo -e "${YELLOW}Note: You may need to run this script with appropriate AWS credentials${NC}"
    return 1
  fi

  read -r ACCESS_KEY SECRET_KEY SESSION_TOKEN <<< "$CREDS"

  if [ -z "$ACCESS_KEY" ] || [ -z "$SECRET_KEY" ] || [ -z "$SESSION_TOKEN" ]; then
    echo -e "${RED}Error: Failed to get valid credentials from role assumption${NC}"
    return 1
  fi

  export AWS_ACCESS_KEY_ID="$ACCESS_KEY"
  export AWS_SECRET_ACCESS_KEY="$SECRET_KEY"
  export AWS_SESSION_TOKEN="$SESSION_TOKEN"

  # Get region (Athena requires explicit region)
  # Try to get from AWS config, environment, or use default
  REGION=$(aws configure get region 2>/dev/null || echo "${AWS_REGION:-ap-southeast-2}")

  # Start query execution
  QUERY_ID=$(aws athena start-query-execution \
    --query-string "$query" \
    --work-group "$WORKGROUP" \
    --region "$REGION" \
    --result-configuration "OutputLocation=s3://$QUERY_RESULTS_BUCKET/validation-results/" \
    --query 'QueryExecutionId' \
    --output text 2>&1)

  if [ -z "$QUERY_ID" ] || [[ "$QUERY_ID" =~ ^[Ee]rror ]] || [[ ! "$QUERY_ID" =~ ^[a-f0-9-]+$ ]]; then
    echo -e "${RED}Error: Failed to start query${NC}"
    echo "Query ID response: $QUERY_ID"
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
    return 1
  fi

  echo "Query ID: $QUERY_ID"
  echo "Waiting for query to complete..."

  # Wait for query to complete
  STATUS="RUNNING"
  ATTEMPTS=0
  MAX_ATTEMPTS=60  # 2 minutes max wait time

  while [ "$STATUS" = "RUNNING" ] || [ "$STATUS" = "QUEUED" ]; do
    sleep 2
    STATUS=$(aws athena get-query-execution \
      --query-execution-id "$QUERY_ID" \
      --region "$REGION" \
      --query 'QueryExecution.Status.State' \
      --output text 2>/dev/null || echo "UNKNOWN")

    ATTEMPTS=$((ATTEMPTS + 1))
    if [ $ATTEMPTS -ge $MAX_ATTEMPTS ]; then
      echo -e "${YELLOW}Warning: Query taking longer than expected, continuing...${NC}"
      break
    fi
  done

  if [ "$STATUS" = "SUCCEEDED" ]; then
    echo -e "${GREEN}Query succeeded!${NC}"
    echo ""

    # Get results
    echo "Query Results:"
    echo "---"

    # Get results and format them nicely
    if command -v jq >/dev/null 2>&1; then
      # Use jq to extract and display results in a readable table format
      RESULTS=$(aws athena get-query-results \
        --query-execution-id "$QUERY_ID" \
        --region "$REGION" \
        --max-items 100 \
        --output json 2>/dev/null)
      RESULT_CODE=$?

      if [ $RESULT_CODE -eq 0 ] && [ -n "$RESULTS" ]; then
        # Extract header row
        HEADER=$(echo "$RESULTS" | jq -r '.ResultSet.Rows[0].Data[]?.VarCharValue // empty' 2>/dev/null | tr '\n' '\t' | sed 's/\t$//')
        if [ -n "$HEADER" ]; then
          echo "$HEADER"
          echo "$HEADER" | sed 's/./-/g'

          # Extract data rows
          echo "$RESULTS" | jq -r '.ResultSet.Rows[1:] | .[] | [.Data[]?.VarCharValue // empty] | @tsv' 2>/dev/null
        else
          echo "No results to display (empty header)"
        fi
      else
        echo "Error retrieving results (code: $RESULT_CODE)"
        # Fallback to table format
        aws athena get-query-results \
          --query-execution-id "$QUERY_ID" \
          --region "$REGION" \
          --max-items 100 \
          --output table 2>/dev/null | tail -n +10
      fi
    else
      # Fallback: use AWS CLI table format but filter to show only data rows
      aws athena get-query-results \
        --query-execution-id "$QUERY_ID" \
        --region "$REGION" \
        --max-items 100 \
        --output table 2>/dev/null | tail -n +10
    fi

    # Also show S3 location for detailed results
    echo ""
    echo "Detailed results available in S3:"
    echo "s3://$QUERY_RESULTS_BUCKET/validation-results/$QUERY_ID.csv"
    echo "---"
  fi

  # Unset credentials after getting results
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

  if [ "$STATUS" != "SUCCEEDED" ]; then
    echo -e "${RED}Query failed with status: $STATUS${NC}"
    ERROR=$(aws athena get-query-execution \
      --query-execution-id "$QUERY_ID" \
      --region "$REGION" \
      --query 'QueryExecution.Status.StateChangeReason' \
      --output text 2>/dev/null)
    echo "Error: $ERROR"

    # Additional diagnostics for common errors
    if [[ "$ERROR" =~ "COLUMN_NOT_FOUND" ]] || [[ "$ERROR" =~ "not authorized" ]]; then
      echo ""
      echo -e "${YELLOW}Diagnostics:${NC}"
      echo "  - Check if table exists: aws glue get-table --database-name $DATABASE_NAME --name $TABLE_NAME"
      echo "  - Check Lake Formation permissions for role: ${role_arn##*/}"
      echo "  - Verify data is uploaded to S3: aws s3 ls s3://$(terraform output -raw lake_bucket_name 2>/dev/null)/sales/"
      echo "  - Ensure enable_lakeformation_governance is set if using governance features"
    fi
  fi

  echo ""
  echo "---"
  echo ""
}

# Validation queries
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Lake Formation Validation Tests${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Test 1: DataAdmin - Should see all rows
if [ -n "$DATAADMIN_ROLE" ]; then
  run_query "$DATAADMIN_ROLE" \
    "SELECT sales_region, COUNT(*) as count FROM $DATABASE_NAME.$TABLE_NAME GROUP BY sales_region ORDER BY sales_region" \
    "DataAdmin: Count by region (should see all regions)"

  run_query "$DATAADMIN_ROLE" \
    "SELECT customer_id, customer_email, ssn, sales_region FROM $DATABASE_NAME.$TABLE_NAME LIMIT 5" \
    "DataAdmin: Sample data with PII (should see all columns including PII)"
fi

# Test 2: Analyst - Should see only APAC rows, no PII
if [ -n "$ANALYST_ROLE" ]; then
  run_query "$ANALYST_ROLE" \
    "SELECT sales_region, COUNT(*) as count FROM $DATABASE_NAME.$TABLE_NAME GROUP BY sales_region ORDER BY sales_region" \
    "Analyst: Count by region (should see only APAC)"

  run_query "$ANALYST_ROLE" \
    "SELECT customer_id, customer_name, sales_region, sales_amount FROM $DATABASE_NAME.$TABLE_NAME LIMIT 5" \
    "Analyst: Sample data (should see only APAC rows, no PII columns)"

  # Test 3: Analyst - Masked view
  run_query "$ANALYST_ROLE" \
    "SELECT customer_id, customer_email, ssn, sales_region FROM $DATABASE_NAME.$VIEW_NAME LIMIT 5" \
    "Analyst: Masked view (should see APAC rows with masked PII)"
fi

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Validation Complete${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}Expected Results:${NC}"
echo "  - DataAdmin should see all regions (APAC, EMEA, AMER) and all columns including PII"
echo "  - Analyst should see only APAC region and no PII columns from base table"
echo "  - Analyst should see APAC rows with masked PII from the view"
echo ""
