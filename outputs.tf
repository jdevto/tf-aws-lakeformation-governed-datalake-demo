output "lake_bucket_name" {
  description = "Name of the data lake S3 bucket"
  value       = aws_s3_bucket.lake.bucket
}

output "query_results_bucket_name" {
  description = "Name of the Athena query results S3 bucket"
  value       = aws_s3_bucket.query_results.bucket
}

output "athena_workgroup_name" {
  description = "Name of the Athena workgroup"
  value       = aws_athena_workgroup.main.name
}

output "dataadmin_role_arn" {
  description = "ARN of the DataAdmin IAM role"
  value       = aws_iam_role.dataadmin.arn
}

output "analyst_role_arn" {
  description = "ARN of the Analyst IAM role"
  value       = aws_iam_role.analyst.arn
}

output "database_name" {
  description = "Name of the Glue database"
  value       = aws_glue_catalog_database.sales_db.name
}

output "table_name" {
  description = "Name of the Glue table"
  value       = aws_glue_catalog_table.sales.name
}

output "view_name" {
  description = "Name of the Athena view"
  value       = local.view_name
}

output "create_view_sql" {
  description = "SQL to create the masked view"
  value       = <<-EOT
    CREATE OR REPLACE VIEW ${local.view_name} AS
    SELECT
      customer_id,
      customer_name,
      REGEXP_REPLACE(customer_email, '^([^@]{1,3}).*@', '***@') AS customer_email,
      REGEXP_REPLACE(ssn, '\\d', '*') AS ssn,
      sales_region,
      sales_amount,
      sale_date
    FROM ${local.database_name}.${local.table_name};
  EOT
}

output "validation_queries" {
  description = "Validation queries to test the setup"
  value = {
    dataadmin_all_data = <<-EOT
      -- Run as DataAdmin: Should see all rows and all columns including PII
      SELECT * FROM ${local.database_name}.${local.table_name}
      ORDER BY sales_region, customer_id
      LIMIT 10;
    EOT

    dataadmin_count_by_region = <<-EOT
      -- Run as DataAdmin: Should see counts for all regions
      SELECT sales_region, COUNT(*) as count
      FROM ${local.database_name}.${local.table_name}
      GROUP BY sales_region
      ORDER BY sales_region;
    EOT

    analyst_filtered_data = <<-EOT
      -- Run as Analyst: Should see only APAC rows, no PII columns
      SELECT * FROM ${local.database_name}.${local.table_name}
      ORDER BY customer_id
      LIMIT 10;
    EOT

    analyst_masked_view = <<-EOT
      -- Run as Analyst: Should see APAC rows with masked PII
      SELECT * FROM ${local.database_name}.${local.view_name}
      ORDER BY customer_id
      LIMIT 10;
    EOT

    analyst_count_by_region = <<-EOT
      -- Run as Analyst: Should see only APAC count
      SELECT sales_region, COUNT(*) as count
      FROM ${local.database_name}.${local.table_name}
      GROUP BY sales_region
      ORDER BY sales_region;
    EOT
  }
}
