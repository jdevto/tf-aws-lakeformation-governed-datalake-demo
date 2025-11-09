# ============================================================================
# Phase 1: Bootstrap - S3, Lake Formation, IAM Roles
# ============================================================================

# Get current AWS account ID
data "aws_caller_identity" "current" {}

# Get current AWS region
data "aws_region" "current" {}

# Random suffix for unique bucket names
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# S3 bucket for data lake
resource "aws_s3_bucket" "lake" {
  bucket = local.lake_bucket_name

  force_destroy = true

  tags = var.tags
}

resource "aws_s3_bucket_versioning" "lake" {
  bucket = aws_s3_bucket.lake.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "lake" {
  bucket = aws_s3_bucket.lake.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "lake" {
  bucket = aws_s3_bucket.lake.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# S3 bucket for Athena query results
resource "aws_s3_bucket" "query_results" {
  bucket = local.query_results_bucket_name

  force_destroy = true

  tags = var.tags
}

resource "aws_s3_bucket_server_side_encryption_configuration" "query_results" {
  bucket = aws_s3_bucket.query_results.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "query_results" {
  bucket = aws_s3_bucket.query_results.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lake Formation Data Lake Settings
# Note: Include current user as admin to allow Terraform to create resources
# The current user's ARN is needed for initial setup
resource "aws_lakeformation_data_lake_settings" "main" {
  # Include both the DataAdmin role and current user as admins
  # Current user ARN format: arn:aws:iam::ACCOUNT:user/USERNAME or arn:aws:sts::ACCOUNT:assumed-role/ROLE/SESSION
  admins = [
    aws_iam_role.dataadmin.arn,
    # Add your current AWS user/role ARN here if needed
    # Or set it via AWS CLI: aws lakeformation put-data-lake-settings --data-lake-settings Admins=arn:aws:iam::ACCOUNT:user/YOUR-USER
  ]
  trusted_resource_owners = [data.aws_caller_identity.current.account_id]
}

# Register S3 location in Lake Formation
resource "aws_lakeformation_resource" "lake_location" {
  arn = aws_s3_bucket.lake.arn

  # Attempt to delete service-linked role before deregistering
  # AWS requires manual deletion of the service-linked role when deregistering
  # the last S3 location
  provisioner "local-exec" {
    when       = destroy
    command    = <<-EOT
      # Try to delete the Lake Formation service-linked role
      # This may fail if it's not the last location or if the role doesn't exist
      ROLE_NAME="AWSServiceRoleForLakeFormationDataAccess"
      aws iam delete-role --role-name "$ROLE_NAME" 2>/dev/null || true
      # Wait a moment for deletion to propagate
      sleep 2
    EOT
    on_failure = continue
  }
}

# IAM Role: DataAdmin
resource "aws_iam_role" "dataadmin" {
  name = "LakeFormation-DataAdmin"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAssumeRole"
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          AWS = data.aws_caller_identity.current.account_id
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "dataadmin" {
  name = "LakeFormation-DataAdmin-Policy"
  role = aws_iam_role.dataadmin.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3ReadAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          aws_s3_bucket.lake.arn,
          "${aws_s3_bucket.lake.arn}/*",
          aws_s3_bucket.query_results.arn,
          "${aws_s3_bucket.query_results.arn}/*"
        ]
      },
      {
        Sid    = "S3WriteAccess"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = [
          "${aws_s3_bucket.lake.arn}/*",
          "${aws_s3_bucket.query_results.arn}/*"
        ]
      },
      {
        Sid    = "GlueReadAccess"
        Effect = "Allow"
        Action = [
          "glue:GetDatabase",
          "glue:GetDatabases",
          "glue:GetTable",
          "glue:GetTables",
          "glue:GetPartition",
          "glue:GetPartitions"
        ]
        Resource = "*"
      },
      {
        Sid    = "AthenaFullAccess"
        Effect = "Allow"
        Action = [
          "athena:*"
        ]
        Resource = "*"
      },
      {
        Sid    = "LakeFormationDataAccess"
        Effect = "Allow"
        Action = [
          "lakeformation:GetDataAccess"
        ]
        Resource = "*"
      }
    ]
  })
}

# IAM Role: Analyst
resource "aws_iam_role" "analyst" {
  name = "LakeFormation-Analyst"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAssumeRole"
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          AWS = data.aws_caller_identity.current.account_id
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "analyst" {
  name = "LakeFormation-Analyst-Policy"
  role = aws_iam_role.analyst.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3ReadAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          aws_s3_bucket.lake.arn,
          "${aws_s3_bucket.lake.arn}/*",
          aws_s3_bucket.query_results.arn,
          "${aws_s3_bucket.query_results.arn}/*"
        ]
      },
      {
        Sid    = "GlueReadAccess"
        Effect = "Allow"
        Action = [
          "glue:GetDatabase",
          "glue:GetDatabases",
          "glue:GetTable",
          "glue:GetTables"
        ]
        Resource = "*"
      },
      {
        Sid    = "AthenaReadAccess"
        Effect = "Allow"
        Action = [
          "athena:GetQueryExecution",
          "athena:GetQueryResults"
        ]
        Resource = "*"
      },
      {
        Sid    = "AthenaWriteAccess"
        Effect = "Allow"
        Action = [
          "athena:StartQueryExecution",
          "athena:StopQueryExecution"
        ]
        Resource = "*"
      },
      {
        Sid    = "LakeFormationDataAccess"
        Effect = "Allow"
        Action = [
          "lakeformation:GetDataAccess"
        ]
        Resource = "*"
      }
    ]
  })
}

# ============================================================================
# Phase 2: Catalog - Glue Database and Table
# ============================================================================

# Glue Database
resource "aws_glue_catalog_database" "sales_db" {
  name        = local.database_name
  description = "Sales database for Lake Formation demo"

  parameters = {
    "classification" = "parquet"
  }

  tags = var.tags
}

# Glue Table
resource "aws_glue_catalog_table" "sales" {
  name          = local.table_name
  database_name = aws_glue_catalog_database.sales_db.name
  description   = "Sales table with PII columns"

  table_type = "EXTERNAL_TABLE"

  parameters = {
    EXTERNAL             = "TRUE"
    "parquet.compress"   = "snappy"
    "projection.enabled" = "false"
  }

  storage_descriptor {
    location      = local.sales_data_path
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      name                  = "sales-parquet"
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"

      parameters = {
        "serialization.format" = "1"
      }
    }

    columns {
      name    = "customer_id"
      type    = "string"
      comment = "Customer identifier"
    }

    columns {
      name    = "customer_name"
      type    = "string"
      comment = "Customer name"
    }

    columns {
      name    = "customer_email"
      type    = "string"
      comment = "Customer email (PII)"
    }

    columns {
      name    = "ssn"
      type    = "string"
      comment = "Social Security Number (PII)"
    }

    columns {
      name    = "sales_region"
      type    = "string"
      comment = "Sales region"
    }

    columns {
      name    = "sales_amount"
      type    = "double"
      comment = "Sales amount"
    }

    columns {
      name    = "sale_date"
      type    = "string"
      comment = "Sale date"
    }
  }
}

# ============================================================================
# Phase 3: Governance - Lake Formation Tags, Filters, and Grants
# ============================================================================
# Note: These resources require Lake Formation admin permissions.
# Set enable_lakeformation_governance = true in variables if you have admin access.

# Lake Formation Tag: PII
# Note: Requires Lake Formation admin permissions to create tags
resource "aws_lakeformation_lf_tag" "pii" {
  count  = var.enable_lakeformation_governance ? 1 : 0
  key    = local.pii_tag_key
  values = ["sensitive", "clear"]

  catalog_id = data.aws_caller_identity.current.account_id

  depends_on = [aws_lakeformation_data_lake_settings.main]
}

# Tag columns as PII sensitive
resource "aws_lakeformation_resource_lf_tags" "customer_email" {
  count = var.enable_lakeformation_governance ? 1 : 0

  table_with_columns {
    name          = aws_glue_catalog_table.sales.name
    database_name = aws_glue_catalog_database.sales_db.name
    column_names  = ["customer_email"]
  }

  lf_tag {
    key   = aws_lakeformation_lf_tag.pii[0].key
    value = local.pii_tag_value
  }

  catalog_id = data.aws_caller_identity.current.account_id

  depends_on = [aws_lakeformation_lf_tag.pii, aws_glue_catalog_table.sales]
}

resource "aws_lakeformation_resource_lf_tags" "ssn" {
  count = var.enable_lakeformation_governance ? 1 : 0

  table_with_columns {
    name          = aws_glue_catalog_table.sales.name
    database_name = aws_glue_catalog_database.sales_db.name
    column_names  = ["ssn"]
  }

  lf_tag {
    key   = aws_lakeformation_lf_tag.pii[0].key
    value = local.pii_tag_value
  }

  catalog_id = data.aws_caller_identity.current.account_id

  depends_on = [aws_lakeformation_lf_tag.pii, aws_glue_catalog_table.sales]
}

# Data Cells Filter for Analyst
resource "aws_lakeformation_data_cells_filter" "analyst_apac" {
  count = var.enable_lakeformation_governance ? 1 : 0

  table_data {
    database_name    = aws_glue_catalog_database.sales_db.name
    name             = local.filter_name
    table_catalog_id = data.aws_caller_identity.current.account_id
    table_name       = aws_glue_catalog_table.sales.name

    # Column filter: include only non-PII columns
    column_names = [
      "customer_id",
      "customer_name",
      "sales_region",
      "sales_amount",
      "sale_date"
    ]

    # Row filter: only APAC region
    row_filter {
      filter_expression = "sales_region = 'APAC'"
    }
  }

  depends_on = [aws_glue_catalog_table.sales]
}

# Grant: DataAdmin ALL on base table
resource "aws_lakeformation_permissions" "dataadmin_table" {
  count = var.enable_lakeformation_governance ? 1 : 0

  principal   = aws_iam_role.dataadmin.arn
  permissions = ["ALL"]

  table {
    database_name = aws_glue_catalog_database.sales_db.name
    name          = aws_glue_catalog_table.sales.name
  }
}

# Grant: Analyst SELECT via data cells filter
resource "aws_lakeformation_permissions" "analyst_filtered" {
  count = var.enable_lakeformation_governance ? 1 : 0

  principal   = aws_iam_role.analyst.arn
  permissions = ["SELECT"]

  data_cells_filter {
    table_catalog_id = data.aws_caller_identity.current.account_id
    table_name       = aws_glue_catalog_table.sales.name
    database_name    = aws_glue_catalog_database.sales_db.name
    name             = aws_lakeformation_data_cells_filter.analyst_apac[0].table_data[0].name
  }

  depends_on = [aws_lakeformation_data_cells_filter.analyst_apac]
}

# Note: Analyst direct table access is implicitly denied by not granting it
# Only the filtered access via data_cells_filter is granted above

# ============================================================================
# Phase 4: Masked Access Path - Athena View
# ============================================================================

# Athena Workgroup
resource "aws_athena_workgroup" "main" {
  name = "lakeformation-demo-workgroup"

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    result_configuration {
      output_location = local.query_results_path

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }

  tags = var.tags

  # Force delete workgroup with recursive option to handle "workgroup not empty" error
  # Terraform's aws_athena_workgroup doesn't support recursive delete directly,
  # but AWS API requires it when workgroup contains query executions
  provisioner "local-exec" {
    when       = destroy
    command    = <<-EOT
      # Get region from AWS config or use default
      REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
      # Delete workgroup with recursive option to remove all query executions
      aws athena delete-work-group \
        --work-group ${self.name} \
        --recursive-delete-option \
        --region "$REGION" 2>/dev/null || true
    EOT
    on_failure = continue
  }

  # Allow provisioner to handle deletion, ignore subsequent Terraform delete attempt
  lifecycle {
    create_before_destroy = false
  }
}

# Grant: Analyst SELECT on Athena view
# Note: Commented out because the view must be created via SQL first (see outputs.create_view_sql)
# After creating the view, uncomment this resource and apply again
# resource "aws_lakeformation_permissions" "analyst_view" {
#   principal   = aws_iam_role.analyst.arn
#   permissions = ["SELECT"]
#
#   table {
#     database_name = aws_glue_catalog_database.sales_db.name
#     name          = local.view_name
#   }
# }
