######################################################
## Secrets
######################################################

resource "random_id" "erlang" {
  byte_length = 8
}

//Create the erlang cookie for cluster joining
resource "aws_ssm_parameter" "erlang_cookie" {
  name  = "/secrets/${var.account}-${var.region}/rabbitmq-ecs-autoclustering/erlang-cookie"
  type  = "SecureString"
  value = "${random_id.erlang.hex}"
}

########################################################
## Networking Rules
########################################################
# define alb security group http ingress rule

resource "aws_security_group" "rabbit_security_group" {
  name        = "${var.service_name}"
  description = "Allow rabbit mq traffic"
  vpc_id      = "${data.terraform_remote_state.vpc.vpc_id}"
}

resource "aws_security_group_rule" "ssh" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = ["10.5.0.0/16"]
  security_group_id = "${aws_security_group.rabbit_security_group.id}"
}

resource "aws_security_group_rule" "5672" {
  type              = "ingress"
  from_port         = 5672
  to_port           = 5672
  protocol          = "tcp"
  cidr_blocks       = ["${data.terraform_remote_state.vpc.vpc_cidr_block}"]
  security_group_id = "${aws_security_group.rabbit_security_group.id}"
}

resource "aws_security_group_rule" "15672" {
  type              = "ingress"
  from_port         = 15672
  to_port           = 15672
  protocol          = "tcp"
  cidr_blocks       = ["${data.terraform_remote_state.vpc.vpc_cidr_block}"]
  security_group_id = "${aws_security_group.rabbit_security_group.id}"
}

resource "aws_security_group_rule" "4369" {
  type              = "ingress"
  from_port         = 4369
  to_port           = 4369
  protocol          = "tcp"
  cidr_blocks       = ["${data.terraform_remote_state.vpc.vpc_cidr_block}"]
  security_group_id = "${aws_security_group.rabbit_security_group.id}"
}

resource "aws_security_group_rule" "25672" {
  type              = "ingress"
  from_port         = 25672
  to_port           = 25672
  protocol          = "tcp"
  cidr_blocks       = ["${data.terraform_remote_state.vpc.vpc_cidr_block}"]
  security_group_id = "${aws_security_group.rabbit_security_group.id}"
}

resource "aws_security_group_rule" "egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = "${aws_security_group.rabbit_security_group.id}"
}

###############################################################################
## ECS Service
###############################################################################

# define ECS service
resource "aws_ecs_service" "service" {
  name                               = "${var.service_name}"
  cluster                            = "${data.terraform_remote_state.ecs_cluster.cluster_name}"
  task_definition                    = "${aws_ecs_task_definition.task.arn}"
  desired_count                      = "${var.desired_count}"
  deployment_minimum_healthy_percent = "66"
  deployment_maximum_percent         = "100"

  service_registries {
    registry_arn   = "${aws_service_discovery_service.service.arn}"
    container_port = "5672"
    container_name = "${var.service_name}"
  }

  ordered_placement_strategy {
    type  = "spread"
    field = "attribute:ecs.availability-zone"
  }

  placement_constraints {
    type = "distinctInstance"
  }
}

# define task definition
resource "aws_ecs_task_definition" "task" {
  family                = "${var.service_name}"
  container_definitions = "${data.template_file.container_definitions.rendered}"
  task_role_arn         = "${aws_iam_role.task.arn}"
}

# render container_definitions
data "template_file" "container_definitions" {
  template = "${file("${path.module}/container-definitions.json.tmpl")}"

  vars = {
    cpu            = "${var.cpu}"
    image          = "${data.terraform_remote_state.build_pipeline.ecr_repository_url}:${var.artifact_version}"
    log_group_name = "${aws_cloudwatch_log_group.service.name}"
    memory         = "${var.memory}"
    name           = "${var.service_name}"
    region         = "${var.region}"
    password       = "guest"
    erlang_cookie  = "${aws_ssm_parameter.erlang_cookie.value}"
  }
}

###############################################################################
## Service Discovery 
###############################################################################

# define service discovery namespace
resource "aws_service_discovery_service" "service" {
  name = "${var.service_name}"

  dns_config {
    namespace_id = "${data.terraform_remote_state.ecs_sd_namespace.namespace_id}"

    dns_records {
      ttl  = 10
      type = "SRV"
    }

    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }
}

###############################################################################
## IAM 
###############################################################################

# define task role
resource "aws_iam_role" "task" {
  name               = "${var.service_name}-task"
  assume_role_policy = "${data.aws_iam_policy_document.assume_role.json}"
}

# define trust policy for task role
data "aws_iam_policy_document" "assume_role" {
  statement {
    effect = "Allow"

    actions = [
      "sts:AssumeRole",
    ]

    # allow ecs to assign the role to the task on our behalf
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    # allow terraform role to assume this role for testing/debugging purposes
    principals {
      type        = "AWS"
      identifiers = ["${data.aws_caller_identity.current.arn}"]
    }
  }
}

# define task policy
resource "aws_iam_policy" "task" {
  name   = "${var.service_name}-task"
  policy = "${data.aws_iam_policy_document.task.json}"
}

# render task policy contents
data "aws_iam_policy_document" "task" {
  # allow app to pull ssm configuration

  # enable cloudwatch log support
  statement {
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:DescribeLogStreams",
      "logs:PutLogEvents",
    ]

    effect = "Allow"

    resources = ["*"]
  }

  # enable autoscaling
  statement {
    actions = [
      "application-autoscaling:*",
      "ecs:StartTelemetrySession",
      "ec2:DescribeInstances",
    ]

    effect = "Allow"

    resources = ["*"]
  }
}

# attach policy to role
resource "aws_iam_policy_attachment" "task" {
  name       = "${var.service_name}-task"
  roles      = ["${aws_iam_role.task.name}"]
  policy_arn = "${aws_iam_policy.task.arn}"
}

###############################################################################
## Cloudwatch Logs & Log Forwarding
###############################################################################

# define cloudwatch log group for container
resource "aws_cloudwatch_log_group" "service" {
  name              = "/aws/ecs/${var.env}/${var.service_name}"
  retention_in_days = "${var.retention_in_days}"
}

# subscribe log forwarder to log group
resource "aws_cloudwatch_log_subscription_filter" "service" {
  name            = "${var.service_name}"
  log_group_name  = "${aws_cloudwatch_log_group.service.name}"
  filter_pattern  = ""
  destination_arn = "${data.terraform_remote_state.log_forwarding.arn}"
  depends_on      = ["aws_lambda_permission.service"]
}

# allow log group to invoke log forwarder
resource "aws_lambda_permission" "service" {
  statement_id   = "${var.service_name}"
  action         = "lambda:InvokeFunction"
  function_name  = "${data.terraform_remote_state.log_forwarding.name}"
  principal      = "logs.${var.region}.amazonaws.com"
  source_account = "${data.aws_caller_identity.current.account_id}"
  source_arn     = "${aws_cloudwatch_log_group.service.arn}"
}
