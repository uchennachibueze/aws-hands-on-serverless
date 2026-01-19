terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}

locals {
  suffix          = substr(replace(data.aws_caller_identity.current.account_id, "-", ""), 0, 6)
  raw_bucket      = "${var.project}-raw-${local.suffix}"
  curated_bucket  = "${var.project}-curated-${local.suffix}"
  table_name      = "${var.project}-events"
  api_name        = "${var.project}-http-api"
  artifact_bucket = "${var.project}-artifacts-${local.suffix}"

  # Placeholder zip file path (must exist in repo under terraform/)
  placeholder_zip = "${path.module}/placeholder.zip"
}

# -------------------------
# Storage: S3 (raw + curated)
# -------------------------
resource "aws_s3_bucket" "raw" {
  bucket = local.raw_bucket
}

resource "aws_s3_bucket" "curated" {
  bucket = local.curated_bucket
}

resource "aws_s3_bucket_public_access_block" "raw" {
  bucket                  = aws_s3_bucket.raw.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "curated" {
  bucket                  = aws_s3_bucket.curated.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "raw" {
  bucket = aws_s3_bucket.raw.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_versioning" "curated" {
  bucket = aws_s3_bucket.curated.id
  versioning_configuration { status = "Enabled" }
}

# Cost-optimal encryption: SSE-S3 (AES256).
resource "aws_s3_bucket_server_side_encryption_configuration" "raw" {
  bucket = aws_s3_bucket.raw.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "curated" {
  bucket = aws_s3_bucket.curated.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# -------------------------
# Database: DynamoDB
# -------------------------
resource "aws_dynamodb_table" "events" {
  name         = local.table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "sk"

  attribute { name = "pk" type = "S" }
  attribute { name = "sk" type = "S" }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  point_in_time_recovery { enabled = true }
}

# -------------------------
# IAM: Lambda role
# -------------------------
resource "aws_iam_role" "lambda_role" {
  name = "${var.project}-lambda-role-${local.suffix}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { Service = "lambda.amazonaws.com" },
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "${var.project}-lambda-policy-${local.suffix}"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
        Resource = "*"
      },
      {
        Effect   = "Allow",
        Action   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:Query"],
        Resource = aws_dynamodb_table.events.arn
      },
      {
        Effect = "Allow",
        Action = ["s3:PutObject", "s3:GetObject"],
        Resource = [
          "${aws_s3_bucket.raw.arn}/*",
          "${aws_s3_bucket.curated.arn}/*"
        ]
      }
    ]
  })
}

# -------------------------
# Lambda functions (Terraform creates infra using a placeholder zip)
# Real code is deployed by CodePipeline (aws lambda update-function-code).
# We ignore changes to filename/source_code_hash so terraform apply won't overwrite deployed code.
# -------------------------
resource "aws_lambda_function" "api" {
  function_name = "${var.project}-api-${local.suffix}"
  role          = aws_iam_role.lambda_role.arn
  runtime       = "python3.11"
  handler       = "app.handler"

  filename         = local.placeholder_zip
  source_code_hash = filebase64sha256(local.placeholder_zip)

  memory_size = 128
  timeout     = 10

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.events.name
      RAW_BUCKET = aws_s3_bucket.raw.bucket
    }
  }

  lifecycle {
    ignore_changes = [
      filename,
      source_code_hash
    ]
  }
}

resource "aws_lambda_function" "etl" {
  function_name = "${var.project}-etl-${local.suffix}"
  role          = aws_iam_role.lambda_role.arn
  runtime       = "python3.11"
  handler       = "app.handler"

  filename         = local.placeholder_zip
  source_code_hash = filebase64sha256(local.placeholder_zip)

  memory_size = 128
  timeout     = 30

  environment {
    variables = {
      CURATED_BUCKET = aws_s3_bucket.curated.bucket
    }
  }

  lifecycle {
    ignore_changes = [
      filename,
      source_code_hash
    ]
  }
}

# Cost control: CloudWatch log retention
resource "aws_cloudwatch_log_group" "api_lg" {
  name              = "/aws/lambda/${aws_lambda_function.api.function_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "etl_lg" {
  name              = "/aws/lambda/${aws_lambda_function.etl.function_name}"
  retention_in_days = var.log_retention_days
}

# -------------------------
# S3 -> ETL Lambda trigger
# -------------------------
resource "aws_lambda_permission" "allow_s3_invoke_etl" {
  statement_id  = "AllowExecutionFromS3"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.etl.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.raw.arn
}

resource "aws_s3_bucket_notification" "raw_notify" {
  bucket = aws_s3_bucket.raw.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.etl.arn
    events              = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_lambda_permission.allow_s3_invoke_etl]
}

# -------------------------
# API Gateway HTTP API (v2)
# -------------------------
resource "aws_apigatewayv2_api" "http_api" {
  name          = local.api_name
  protocol_type = "HTTP"

  cors_configuration {
    allow_headers = ["content-type", "authorization"]
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_origins = ["*"]
  }
}

resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id                 = aws_apigatewayv2_api.http_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.api.arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "post_events" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "POST /events"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

resource "aws_apigatewayv2_route" "options_events" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "OPTIONS /events"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id       = aws_apigatewayv2_api.http_api.id
  name         = "$default"
  auto_deploy  = true
}

resource "aws_lambda_permission" "allow_apigw_invoke" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*"
}

# =========================================================
# CI/CD: CodePipeline + CodeBuild (optional, enabled by var)
# =========================================================
resource "aws_s3_bucket" "artifacts" {
  count  = var.enable_pipeline ? 1 : 0
  bucket = local.artifact_bucket
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  count                  = var.enable_pipeline ? 1 : 0
  bucket                 = aws_s3_bucket.artifacts[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  count  = var.enable_pipeline ? 1 : 0
  bucket = aws_s3_bucket.artifacts[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# CodeBuild roles
resource "aws_iam_role" "codebuild_role" {
  count = var.enable_pipeline ? 1 : 0
  name  = "${var.project}-codebuild-role-${local.suffix}"

  assume_role_policy = jsonencode({
    Version="2012-10-17",
    Statement=[{
      Effect="Allow",
      Principal={ Service="codebuild.amazonaws.com" },
      Action="sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "codebuild_policy" {
  count = var.enable_pipeline ? 1 : 0
  name  = "${var.project}-codebuild-policy-${local.suffix}"
  role  = aws_iam_role.codebuild_role[0].id

  # Learning-friendly. Tighten later.
  policy = jsonencode({
    Version="2012-10-17",
    Statement=[
      {
        Effect="Allow",
        Action=["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"],
        Resource="*"
      },
      {
        Effect="Allow",
        Action=["s3:GetObject","s3:PutObject","s3:GetObjectVersion","s3:GetBucketLocation"],
        Resource=[
          aws_s3_bucket.artifacts[0].arn,
          "${aws_s3_bucket.artifacts[0].arn}/*"
        ]
      },
      {
        Effect="Allow",
        Action=[
          # Terraform provisioning (broad while learning)
          "iam:*","lambda:*","apigateway:*","dynamodb:*","s3:*","logs:*","events:*","cloudwatch:*","sts:*"
        ],
        Resource="*"
      }
    ]
  })
}

resource "aws_codebuild_project" "build" {
  count        = var.enable_pipeline ? 1 : 0
  name         = "${var.project}-build-${local.suffix}"
  service_role = aws_iam_role.codebuild_role[0].arn

  artifacts { type = "CODEPIPELINE" }

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/standard:7.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = false
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec-build.yml"
  }
}

resource "aws_codebuild_project" "deploy" {
  count        = var.enable_pipeline ? 1 : 0
  name         = "${var.project}-deploy-${local.suffix}"
  service_role = aws_iam_role.codebuild_role[0].arn

  artifacts { type = "CODEPIPELINE" }

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/standard:7.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = false
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec-deploy.yml"
  }
}

# CodePipeline role
resource "aws_iam_role" "codepipeline_role" {
  count = var.enable_pipeline ? 1 : 0
  name  = "${var.project}-codepipeline-role-${local.suffix}"

  assume_role_policy = jsonencode({
    Version="2012-10-17",
    Statement=[{
      Effect="Allow",
      Principal={ Service="codepipeline.amazonaws.com" },
      Action="sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "codepipeline_policy" {
  count = var.enable_pipeline ? 1 : 0
  name  = "${var.project}-codepipeline-policy-${local.suffix}"
  role  = aws_iam_role.codepipeline_role[0].id

  policy = jsonencode({
    Version="2012-10-17",
    Statement=[
      {
        Effect="Allow",
        Action=["s3:GetObject","s3:GetObjectVersion","s3:PutObject","s3:GetBucketLocation"],
        Resource=[
          aws_s3_bucket.artifacts[0].arn,
          "${aws_s3_bucket.artifacts[0].arn}/*"
        ]
      },
      {
        Effect="Allow",
        Action=["codebuild:BatchGetBuilds","codebuild:StartBuild"],
        Resource="*"
      },
      {
        Effect="Allow",
        Action=["codestar-connections:UseConnection"],
        Resource="*"
      }
    ]
  })
}

resource "aws_codepipeline" "pipeline" {
  count    = var.enable_pipeline ? 1 : 0
  name     = "${var.project}-pipeline-${local.suffix}"
  role_arn = aws_iam_role.codepipeline_role[0].arn

  artifact_store {
    location = aws_s3_bucket.artifacts[0].bucket
    type     = "S3"
  }

  stage {
    name = "Source"
    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source_output"]
      configuration = {
        ConnectionArn    = var.codestar_connection_arn
        FullRepositoryId = "${var.github_owner}/${var.github_repo}"
        BranchName       = var.github_branch
        DetectChanges    = "true"
      }
    }
  }

  stage {
    name = "Build"
    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source_output"]
      output_artifacts = ["build_output"]
      configuration = {
        ProjectName = aws_codebuild_project.build[0].name
      }
    }
  }

  stage {
    name = "Deploy"
    action {
      name            = "Deploy"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["build_output"]
      configuration = {
        ProjectName = aws_codebuild_project.deploy[0].name
      }
    }
  }
}
