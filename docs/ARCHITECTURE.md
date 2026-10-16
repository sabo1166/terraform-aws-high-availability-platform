# Architecture

The overview diagram and design notes are in the [README](../README.md). This file adds the details needed to operate or modify the stack.

## Request path

1. DNS (optional): Route 53 A/AAAA alias → CloudFront.
2. CloudFront terminates TLS and redirects HTTP to HTTPS, then forwards to the external ALB over HTTP:80 with `X-Origin-Verify: <secret>`.
3. The external ALB (public subnets) has one forwarding rule that matches that header; the listener's default action is a fixed 403.
4. Frontend instances (private app subnets) serve static content and proxy `/api/*` to the internal ALB.
5. The internal ALB forwards to backend instances on 8080.
6. Backend instances reach RDS on 5432. Outbound internet (packages, SSM) goes through the NAT gateway in the instance's own AZ.

| CloudFront behavior | Cache policy | Methods |
|---|---|---|
| `/static/*` | `Managed-CachingOptimized` | GET, HEAD, OPTIONS |
| `/api/*` | `Managed-CachingDisabled` + `Managed-AllViewer` | all |
| default | `Managed-CachingDisabled` + `Managed-AllViewer` | GET, HEAD, OPTIONS |

## Subnets (defaults)

| Tier | CIDRs (AZ a / b / c) | Default route |
|---|---|---|
| Public | 10.0.0.0/24, 10.0.1.0/24, 10.0.2.0/24 | Internet gateway |
| Private app | 10.0.10.0/24, 10.0.11.0/24, 10.0.12.0/24 | NAT in the same AZ (or the single NAT) |
| Isolated DB | 10.0.20.0/24, 10.0.21.0/24, 10.0.22.0/24 | none |

Only the first `az_count` entries are created. An S3 gateway endpoint is attached to the private app route tables.

## Security groups

| Group | Ingress | Egress |
|---|---|---|
| ext-alb | 80 from the CloudFront origin-facing prefix list | 80 → frontend |
| frontend | 80 from ext-alb | 80 → int-alb; 80 and 443 → `0.0.0.0/0` |
| int-alb | 80 from frontend | 8080 → backend |
| backend | 8080 from int-alb | 5432 → rds; 80 and 443 → `0.0.0.0/0` |
| rds | 5432 from backend | none |
| VPC default | none | none |

Ports 80/443 to the internet are used for package installation and Session Manager. Interface endpoints for `ssm`, `ssmmessages` and `ec2messages` would remove that dependency on NAT at an hourly cost per endpoint per AZ.

## IAM

- Frontend: `AmazonSSMManagedInstanceCore`.
- Backend: the same, plus `secretsmanager:GetSecretValue` and `DescribeSecret` on the RDS-managed secret.
- Separate roles for RDS enhanced monitoring and for VPC flow logs.

## Failure behavior

| Event | Result |
|---|---|
| Instance fails health checks (3 × 15 s) | Removed from the target group; the ASG replaces it (health check type is ELB). |
| AZ unavailable | ALBs route to the remaining AZ. With `nat_gateway_mode = "per_az"` the surviving AZ keeps its own egress; with `"single"` and the NAT's AZ down, private egress is lost. |
| RDS primary or AZ failure | Multi-AZ failover to the standby; the endpoint name is unchanged and clients must reconnect. AWS documents this as typically 60–120 seconds. |
| Launch template change | Rolling instance refresh, keeping at least 50% healthy. A `user_data` that breaks every new instance will stall the refresh. |

Not covered: regional failure, restoring corrupted data, and CloudFront's single ALB origin (the ALB itself spans AZs).

## Scaling

Target tracking on average CPU (50%). Request count per target would suit the frontend better and is not implemented.

## Database

`db.t3.micro`, gp3, storage autoscaling to 100 GiB, encrypted with the default KMS key, parameter group `rds.force_ssl=1`, final snapshot named `<project>-<env>-postgres-final` on destroy. That fixed name means a second destroy fails while the first snapshot still exists; delete it first (see `COST_AND_CLEANUP.md`).

## Logs and alarms

- Flow logs (`/<project>-<env>/vpc-flow-logs`) and the RDS `postgresql` and `upgrade` logs go to CloudWatch Logs with `log_retention_days` (default 30). The RDS log groups are created by Terraform before the instance so the retention applies.
- Alarms (all notify the SNS topic): external ALB 5xx, internal ALB target 5xx, unhealthy hosts for each target group, ASG CPU for each tier, RDS CPU, free storage and connections, CloudFront 5xx rate.

## Plan-time checks

- `data.aws_ami.app` postconditions: AMI is `available`, `Linux/UNIX`, `x86_64` or `arm64`.
- `terraform_data.preflight` preconditions: both instance types support the AMI's architecture; the root device is EBS; the AMI owner matches `ami_owner_id` when that is set; `domain_name` and `hosted_zone_name` are set together and consistent; `db_parameter_group_family` matches the major version of `db_engine_version`; `db_max_allocated_storage` is 0 or at least `db_allocated_storage`.
- Variable validation: region fixed to `us-east-1`, ASG minimum ≥ 2, backup retention 1–35 days, `az_count` 2–3, `db_allocated_storage` ≥ 20, names without double or trailing hyphens.
