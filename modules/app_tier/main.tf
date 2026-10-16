# One application tier: IAM role + instance profile, launch template (IMDSv2, encrypted root),
# ASG (ELB health checks) and CPU target-tracking. Instantiated once for frontend, once for backend.

############################
# IAM (least privilege per tier)
############################
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "${var.name}-${var.tier}"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

# Session Manager access instead of SSH (no inbound ports, no key pairs).
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "secrets" {
  count = length(var.secret_arns) > 0 ? 1 : 0

  statement {
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = var.secret_arns
  }
}

resource "aws_iam_role_policy" "secrets" {
  count = length(var.secret_arns) > 0 ? 1 : 0

  name   = "read-secrets"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.secrets[0].json
}

resource "aws_iam_instance_profile" "this" {
  name = "${var.name}-${var.tier}"
  role = aws_iam_role.this.name
}

############################
# Launch template
############################
resource "aws_launch_template" "this" {
  name_prefix            = "${var.name}-${var.tier}-"
  image_id               = var.ami_id
  instance_type          = var.instance_type
  update_default_version = true
  user_data              = base64encode(var.user_data)

  iam_instance_profile {
    name = aws_iam_instance_profile.this.name
  }

  vpc_security_group_ids = var.security_group_ids

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  # Encrypt the root volume. Device name comes from the AMI itself (differs per distro);
  # size is left unset so it inherits the AMI snapshot size.
  block_device_mappings {
    device_name = var.root_device_name
    ebs {
      encrypted             = true
      volume_type           = "gp3"
      delete_on_termination = true
    }
  }

  monitoring {
    enabled = true
  }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.name}-${var.tier}", Tier = var.tier }
  }
  tag_specifications {
    resource_type = "volume"
    tags          = { Name = "${var.name}-${var.tier}", Tier = var.tier }
  }

  lifecycle {
    create_before_destroy = true
  }
}

############################
# Auto Scaling group
############################
resource "aws_autoscaling_group" "this" {
  name                      = "${var.name}-${var.tier}"
  min_size                  = var.capacity.min
  desired_capacity          = var.capacity.desired
  max_size                  = var.capacity.max
  vpc_zone_identifier       = var.subnet_ids
  target_group_arns         = var.target_group_arns
  health_check_type         = "ELB"
  health_check_grace_period = 300
  default_instance_warmup   = 120
  metrics_granularity       = "1Minute"
  enabled_metrics           = ["GroupInServiceInstances", "GroupDesiredCapacity", "GroupTotalInstances"]

  launch_template {
    id      = aws_launch_template.this.id
    version = aws_launch_template.this.latest_version
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  tag {
    key                 = "Name"
    value               = "${var.name}-${var.tier}"
    propagate_at_launch = true
  }

  lifecycle {
    ignore_changes = [desired_capacity] # let target tracking own the live value
  }
}

resource "aws_autoscaling_policy" "cpu" {
  name                   = "${var.name}-${var.tier}-cpu-target"
  autoscaling_group_name = aws_autoscaling_group.this.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = var.cpu_target_percent
  }
}
