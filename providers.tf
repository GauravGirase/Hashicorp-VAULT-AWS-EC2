terraform {
  required_providers {
    aws = {
        version = "6.36.0"
        source = "hashicorp/aws"
    }
  }
}

provider "aws" {
  region = "ap-south-1"
}