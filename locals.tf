locals {
  # S3 bucket names with random suffix to avoid duplicates
  lake_bucket_name          = "lakeformation-demo-lake-${random_id.bucket_suffix.hex}"
  query_results_bucket_name = "lakeformation-demo-query-results-${random_id.bucket_suffix.hex}"

  # Database and table names
  database_name = "sales_db"
  table_name    = "sales"
  view_name     = "sales_masked"

  # S3 paths
  sales_data_path    = "s3://${aws_s3_bucket.lake.bucket}/sales/"
  query_results_path = "s3://${aws_s3_bucket.query_results.bucket}/athena-results/"

  # Lake Formation tag
  pii_tag_key   = "pii"
  pii_tag_value = "sensitive"

  # Data cells filter
  filter_name = "analyst-apac-filter"
}
