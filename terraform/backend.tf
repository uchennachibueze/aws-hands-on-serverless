terraform {
  backend "s3" {
    bucket         = "tfstate-aws-hands-on-244862164728-us-east-1"
    key            = "aws-hands-on/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "tf-lock-aws-hands-on"
    encrypt        = true
  }
}
