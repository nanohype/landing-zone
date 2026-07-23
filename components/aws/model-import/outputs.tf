output "staging_bucket_name" {
  description = "Name of the account+region-scoped S3 bucket where open-weight model files are staged for Bedrock Custom Model Import"
  value       = aws_s3_bucket.staging.bucket
}

output "staging_bucket_arn" {
  description = "ARN of the model-import staging bucket"
  value       = aws_s3_bucket.staging.arn
}

output "import_role_arn" {
  description = "ARN of the IAM service role Bedrock assumes to read staged weights during a CreateModelImportJob"
  value       = aws_iam_role.import.arn
}
