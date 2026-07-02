terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 6.53.0"
      configuration_aliases = [aws.acm]
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.8.0"
    }
  }
  required_version = "~> 1.4"
}

variable "deployment_name" {
  type = string
}

