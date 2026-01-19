output "api_base_url" {
value = aws_apigatewayv2_api.http_api.api_endpoint
}
output "raw_bucket" {
value = aws_s3_bucket.raw.bucket
}
output "curated_bucket" {
value = aws_s3_bucket.curated.bucket
}
output "dynamodb_table" {
value = aws_dynamodb_table.events.name
}
output "api_lambda_name" {
value = aws_lambda_function.api.function_name
}
output "etl_lambda_name" {
value = aws_lambda_function.etl.function_name
}
output "pipeline_name" {
value = try(aws_codepipeline.pipeline[0].name, "")
description = "Created only when enable_pipeline=true"
}