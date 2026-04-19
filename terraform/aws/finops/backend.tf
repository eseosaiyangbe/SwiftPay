terraform {
  backend "s3" {
    bucket         = "swiftpay-tfstate-334091769766"
    key            = "aws/finops/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "swiftpay-tfstate-lock"
    encrypt        = true
  }
}
