variable "region" {
type = string
description = "AWS region to deploy into."
default = "us-east-1"
}
variable "project" {
type = string
description = "Project prefix for resource names."
default = "aws-hands-on"
}
# --- CodePipeline inputs ---
variable "enable_pipeline" {
type = bool
description = "Whether to create CodePipeline/CodeBuild resources."
default = true
}
variable "codestar_connection_arn" {
type = string
description = "ARN of an existing CodeStar Connections connection to GitHub."
default = ""
}
variable "github_owner" {
type = string
description = "GitHub org/user."
default = ""
}
variable "github_repo" {
type = string
description = "GitHub repository name."
default = ""
}
variable "github_branch" {
type = string
description = "Branch to build/deploy."
default = "main"
}
variable "log_retention_days" {
type = number
description = "CloudWatch Logs retention for Lambda log groups."
default = 14
}
