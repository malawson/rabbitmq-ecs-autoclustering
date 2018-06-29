data "aws_caller_identity" "current" {}

# define empty terraform configuration for terragrunt to manage
terraform {
  backend "s3" {}
}

# configure aws provider
provider "aws" {
  region = "${var.region}"
}

data "aws_iam_policy_document" "ecs_role" {
  statement {
    effect = "Allow"

    actions = [
      "sts:AssumeRole",
    ]

    principals {
      type        = "Service"
      identifiers = ["ecs.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "ecs_service" {
  statement {
    effect = "Allow"

    actions = [
      "ec2:Describe*",
      "ecs:StartTelemetrySession",
    ]

    resources = ["*"]
  }
}

#Policies for log forwarding
data "aws_iam_policy_document" "cloudwatch_lambda_assume_role" {
  statement {
    effect = "Allow"

    actions = [
      "sts:AssumeRole",
    ]

    principals {
      type = "Service"

      identifiers = [
        "lambda.amazonaws.com",
      ]
    }
  }
}

# import state from build pipeline
data "terraform_remote_state" "build_pipeline" {
  backend = "s3"

  config {
    bucket     = "${lookup(var.remote_state, "ops")}"
    encrypt    = true
    key        = "${var.region}/build-pipelines/pa-api-gateway/terraform.tfstate"
    lock_table = "${lookup(var.lock_table, "ops")}"
    region     = "us-east-1"
  }
}

# import log forwarding state from the appropriate account
data "terraform_remote_state" "ecs_cluster" {
  backend = "s3"

  config {
    bucket     = "${lookup(var.remote_state, var.account)}"
    encrypt    = true
    key        = "${var.region}/${var.cluster_alias}/terraform.tfstate"
    lock_table = "${lookup(var.lock_table, var.account)}"
    region     = "us-east-1"
  }
}

# import service discovery state from the appropriate account
data "terraform_remote_state" "ecs_sd_namespace" {
  backend = "s3"

  config {
    bucket     = "${lookup(var.remote_state, var.account)}"
    encrypt    = true
    key        = "${var.region}/${var.ecs_sd_alias}/terraform.tfstate"
    lock_table = "${lookup(var.lock_table, var.account)}"
    region     = "us-east-1"
  }
}

# import state from the environment's log forwarder
data "terraform_remote_state" "log_forwarding" {
  backend = "s3"

  config {
    bucket     = "${lookup(var.remote_state, var.account)}"
    encrypt    = true
    key        = "${var.region}/log-forwarding/terraform.tfstate"
    lock_table = "${lookup(var.lock_table, var.account)}"
    region     = "us-east-1"
  }
}

# import sns alerting state from the appropriate account
data "terraform_remote_state" "sns_alerting" {
  backend = "s3"

  config {
    bucket     = "${lookup(var.remote_state, "ops")}"
    encrypt    = true
    key        = "${var.region}/sns-alerting/terraform.tfstate"
    lock_table = "${lookup(var.lock_table, "ops")}"
    region     = "us-east-1"
  }
}

# import vpc state from the appropriate account
data "terraform_remote_state" "vpc" {
  backend = "s3"

  config {
    bucket     = "${lookup(var.remote_state, var.account)}"
    encrypt    = true
    key        = "${var.region}/${var.vpc_alias}/terraform.tfstate"
    lock_table = "${lookup(var.lock_table, var.account)}"
    region     = "us-east-1"
  }
}
