# Offline tests: the AWS provider is mocked, so nothing contacts AWS and nothing is created.
# Run: terraform test

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }

  mock_data "aws_ami" {
    defaults = {
      id               = "ami-0ed59cbb87dfa8dba"
      state            = "available"
      architecture     = "x86_64"
      platform_details = "Linux/UNIX"
      root_device_name = "/dev/xvda"
      root_device_type = "ebs"
      name             = "mock-ami"
      owner_id         = "000000000000"
    }
  }

  mock_data "aws_ec2_instance_type" {
    defaults = {
      supported_architectures = ["x86_64"]
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_data "aws_route53_zone" {
    defaults = {
      zone_id = "Z0000000000000"
    }
  }

  mock_resource "aws_db_instance" {
    defaults = {
      address = "mock-db.example.internal"
      port    = 5432
      master_user_secret = [{
        secret_arn              = "arn:aws:secretsmanager:us-east-1:000000000000:secret:mock"
        kms_key_id              = "mock"
        secret_status           = "active"
        secret_rotation_enabled = false
      }]
    }
  }
}

mock_provider "random" {}

run "defaults_are_highly_available" {
  command = plan

  assert {
    condition     = length(module.network.public_subnet_ids) == 2 && length(module.network.app_subnet_ids) == 2 && length(module.network.db_subnet_ids) == 2
    error_message = "Expected two subnets per tier by default."
  }
  assert {
    condition     = length(module.network.nat_gateway_ids) == 2
    error_message = "Default NAT mode must be one per AZ."
  }
  assert {
    condition     = module.database.settings.multi_az && module.database.settings.storage_encrypted && !module.database.settings.publicly_accessible
    error_message = "RDS must be Multi-AZ, encrypted and private."
  }
  assert {
    condition     = module.database.settings.backup_retention_period > 0
    error_message = "RDS backups must be enabled."
  }
  assert {
    condition     = module.frontend.settings.min_size >= 2 && module.backend.settings.min_size >= 2
    error_message = "ASG minimum must be >= 2."
  }
  assert {
    condition     = module.frontend.settings.health_check_type == "ELB" && module.backend.settings.health_check_type == "ELB"
    error_message = "ASGs must use ELB health checks."
  }
  assert {
    condition     = module.frontend.settings.image_id == "ami-0ed59cbb87dfa8dba" && module.backend.settings.image_id == "ami-0ed59cbb87dfa8dba"
    error_message = "Launch templates must use the mandated AMI by default."
  }
  assert {
    condition     = module.frontend.settings.imds_tokens == "required" && module.backend.settings.imds_tokens == "required"
    error_message = "IMDSv2 must be required."
  }
  assert {
    condition     = module.edge.default_viewer_protocol_policy == "redirect-to-https"
    error_message = "CloudFront must redirect HTTP to HTTPS."
  }
  assert {
    condition     = length(module.edge.dns_record_names) == 0 && module.edge.acm_certificate_arn == null
    error_message = "No DNS/ACM resources without a domain."
  }
  assert {
    condition     = !contains(module.network.public_subnets_auto_assign_public_ip, true)
    error_message = "No auto-assign public IPs."
  }
}

run "custom_domain_creates_acm_and_alias_records" {
  command = plan

  variables {
    domain_name      = "app.example.com"
    hosted_zone_name = "example.com"
  }

  assert {
    condition     = length(module.edge.dns_record_names) == 2
    error_message = "Expected A and AAAA alias records."
  }
}

run "single_nat_mode_creates_one_nat" {
  command = plan

  variables {
    nat_gateway_mode = "single"
  }

  assert {
    condition     = length(module.network.nat_gateway_ids) == 1
    error_message = "single mode must create exactly one NAT gateway."
  }
}
run "matching_ami_owner_is_accepted" {
  command = plan

  variables {
    ami_owner_id = "000000000000"
  }

  assert {
    condition     = module.frontend.settings.image_id == "ami-0ed59cbb87dfa8dba"
    error_message = "A matching owner must not block the plan."
  }
}

run "wrong_ami_owner_is_rejected" {
  command = plan

  variables {
    ami_owner_id = "111111111111"
  }

  expect_failures = [terraform_data.preflight]
}

run "engine_and_parameter_family_mismatch_is_rejected" {
  command = plan

  variables {
    db_engine_version = "17"
  }

  expect_failures = [terraform_data.preflight]
}

run "matching_engine_and_family_is_accepted" {
  command = plan

  variables {
    db_engine_version         = "17.2"
    db_parameter_group_family = "postgres17"
  }

  assert {
    condition     = module.database.settings.multi_az
    error_message = "A consistent engine/family pair must plan cleanly."
  }
}

run "storage_ceiling_below_initial_is_rejected" {
  command = plan

  variables {
    db_allocated_storage     = 50
    db_max_allocated_storage = 30
  }

  expect_failures = [terraform_data.preflight]
}

run "domain_without_zone_is_rejected" {
  command = plan

  variables {
    domain_name = "app.example.com"
  }

  expect_failures = [terraform_data.preflight]
}

run "arm_ami_with_x86_instance_type_is_rejected" {
  command = plan

  override_data {
    target = data.aws_ami.app
    values = {
      id               = "ami-0ed59cbb87dfa8dba"
      state            = "available"
      architecture     = "arm64"
      platform_details = "Linux/UNIX"
      root_device_name = "/dev/xvda"
      root_device_type = "ebs"
    }
  }

  expect_failures = [terraform_data.preflight]
}

run "single_az_capacity_is_rejected" {
  command = plan

  variables {
    frontend_capacity = { min = 1, desired = 1, max = 2 }
  }

  expect_failures = [var.frontend_capacity]
}

run "non_us_east_1_region_is_rejected" {
  command = plan

  variables {
    region = "eu-west-1"
  }

  expect_failures = [var.region]
}
