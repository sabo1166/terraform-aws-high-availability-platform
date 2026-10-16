locals {
  name = "${var.project_name}-${var.environment}"

  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)
}

data "aws_availability_zones" "available" {
  #checkov:skip=CKV_AWS_394:Only the first az_count zones are used; set membership drift is acceptable for a lab
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

# The mandated AMI. A missing/unshared/unavailable AMI fails the plan right here.
data "aws_ami" "app" {
  filter {
    name   = "image-id"
    values = [var.ami_id]
  }

  lifecycle {
    postcondition {
      condition     = self.state == "available"
      error_message = "AMI ${var.ami_id} is not in state 'available' (state: ${self.state})."
    }
    postcondition {
      condition     = self.platform_details == "Linux/UNIX"
      error_message = "AMI ${var.ami_id} platform is '${self.platform_details}'; the bootstrap scripts require a Linux/UNIX AMI."
    }
    postcondition {
      condition     = contains(["x86_64", "arm64"], self.architecture)
      error_message = "AMI ${var.ami_id} architecture '${self.architecture}' is unsupported (need x86_64 or arm64)."
    }
  }
}

data "aws_ec2_instance_type" "frontend" {
  instance_type = var.frontend_instance_type
}

data "aws_ec2_instance_type" "backend" {
  instance_type = var.backend_instance_type
}

data "aws_ec2_managed_prefix_list" "cloudfront_origin" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

# Plan-time guard rails. Failing any condition aborts plan/apply before anything is created.
resource "terraform_data" "preflight" {
  lifecycle {
    precondition {
      condition     = contains(data.aws_ec2_instance_type.frontend.supported_architectures, data.aws_ami.app.architecture)
      error_message = "frontend_instance_type ${var.frontend_instance_type} does not support the AMI architecture ${data.aws_ami.app.architecture}."
    }
    precondition {
      condition     = contains(data.aws_ec2_instance_type.backend.supported_architectures, data.aws_ami.app.architecture)
      error_message = "backend_instance_type ${var.backend_instance_type} does not support the AMI architecture ${data.aws_ami.app.architecture}."
    }
    precondition {
      condition     = var.ami_owner_id == null || data.aws_ami.app.owner_id == var.ami_owner_id
      error_message = "AMI ${var.ami_id} is owned by account ${data.aws_ami.app.owner_id}, not the expected ami_owner_id."
    }
    precondition {
      condition     = (var.domain_name == null) == (var.hosted_zone_name == null)
      error_message = "Set domain_name and hosted_zone_name together, or leave both null."
    }
    precondition {
      condition     = var.domain_name == null || endswith(var.domain_name, var.hosted_zone_name == null ? "" : var.hosted_zone_name)
      error_message = "domain_name must be inside hosted_zone_name (e.g. app.example.com in example.com)."
    }
    precondition {
      condition     = startswith(var.db_parameter_group_family, "postgres${split(".", var.db_engine_version)[0]}")
      error_message = "db_parameter_group_family (${var.db_parameter_group_family}) does not match the major version of db_engine_version (${var.db_engine_version})."
    }
    precondition {
      condition     = var.db_max_allocated_storage == 0 || var.db_max_allocated_storage >= var.db_allocated_storage
      error_message = "db_max_allocated_storage must be 0 (disabled) or at least db_allocated_storage."
    }
    precondition {
      condition     = data.aws_ami.app.root_device_type == "ebs"
      error_message = "AMI root device type is '${data.aws_ami.app.root_device_type}'; an EBS-backed AMI is required."
    }
  }
}
