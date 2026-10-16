# Cost and cleanup

> Figures are **rough us-east-1 on-demand estimates for planning only** (not queried from AWS). Check the AWS Pricing Calculator before applying. Expect on the order of **US$150–250 per month** if left running with defaults, dominated by NAT, RDS Multi-AZ, ALBs and EC2.

## Billable resources (default configuration)

| Resource | Count | Driver | Notes |
|---|---|---|---|
| NAT Gateway | 2 (`per_az`) | hourly (~$0.045/h each ≈ $33/mo) + per-GB processed | `nat_gateway_mode = "single"` halves the hourly cost but makes one AZ a single point of failure for egress |
| Public IPv4 addresses | 2 NAT EIPs + ALB node IPs | ~$0.005/h each | applies to all in-use public IPv4 |
| Application Load Balancers | 2 | hourly (~$16/mo each) + LCU | internal + external |
| EC2 | 4 × `t3.micro` (2 front, 2 back) | hourly + EBS gp3 root + detailed monitoring | grows with ASG max 4+4; detailed monitoring adds a small per-metric fee |
| RDS PostgreSQL Multi-AZ | `db.t3.micro` ×2 (primary+standby) | hourly + 20 GiB gp3 ×2 + backups beyond DB size + enhanced monitoring logs | final snapshot persists after destroy |
| CloudFront | 1 distribution | per-request + data out (free tier covers a lot) | PriceClass_100 by default |
| Route 53 | 1 hosted zone (pre-existing, not created) + queries | $0.50/zone/mo, per-query | alias queries to CloudFront are free |
| ACM public cert | 1 | free | |
| CloudWatch | ~10 alarms, flow logs, RDS logs | $0.10/alarm/mo; log ingestion/storage | flow logs can be sizeable: `enable_flow_logs = false` to disable |
| Secrets Manager | 1 RDS-managed secret | ~$0.40/mo + API calls | |
| SNS | 1 topic | negligible | |
| S3 gateway endpoint | 1 | free | |
| S3 state bucket (if you create one) | 1 | pennies | created outside this stack |

Cheaper lab levers (documented trade-offs): `nat_gateway_mode = "single"`; `enable_flow_logs = false`; `*_capacity` min stays ≥ 2 by validation (HA); `db_multi_az = false` halves RDS cost but removes the DB failover guarantee. **Stop paying: destroy the stack.** (EC2/RDS "stop" does not stop NAT/ALB charges, and Multi-AZ RDS cannot be stopped indefinitely.)

## Teardown sequence

Only destroy what this stack created. `terraform destroy` acts only on resources in *this* state; it does not touch the hosted zone (read via data source), your domain registration, or anything else in the account. Review the plan first.

1. **Confirm you are in the right account/region**
   ```bash
   aws sts get-caller-identity
   terraform workspace show ; terraform state list | wc -l
   ```
2. **Take or confirm a backup if the data matters.** Destroy takes a final snapshot named `<project>-<env>-postgres-final` unless `db_skip_final_snapshot = true`. The name is fixed, so a later destroy fails while an earlier final snapshot still exists; delete the old one first.
   ```bash
   aws rds create-db-snapshot --db-instance-identifier ha-web-lab-postgres --db-snapshot-identifier manual-before-destroy
   ```
3. **Intentionally lift deletion protection** (guard rail on by default). In `terraform.tfvars`:
   ```hcl
   db_deletion_protection  = false
   alb_deletion_protection = false
   # db_skip_final_snapshot = true   # ONLY if the data is disposable
   ```
   ```bash
   terraform apply -target=module.database.aws_db_instance.main -target=aws_lb.external -target=aws_lb.internal
   ```
   (The `terraform-destroy.yml` workflow does this for you.)
4. **Preview the destroy**
   ```bash
   terraform plan -destroy
   ```
5. **Destroy** (CloudFront disable/delete and RDS Multi-AZ deletion each take several minutes)
   ```bash
   terraform destroy
   ```
6. **Verify nothing billable remains**
   ```bash
   aws ec2 describe-nat-gateways --filter Name=state,Values=available,pending --query 'NatGateways[].NatGatewayId'
   aws ec2 describe-addresses --query 'Addresses[].[PublicIp,AssociationId]'        # unattached EIPs bill
   aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'
   aws rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier'
   aws cloudfront list-distributions --query 'DistributionList.Items[].[Id,Status,Enabled]'
   ```
7. **Optional leftovers** (not deleted automatically, may keep costing): the final/manual RDS snapshot (`aws rds delete-db-snapshot ...` when no longer needed), the RDS log groups `/aws/rds/instance/<name>-postgres/*` (managed by Terraform, so removed with the stack), the remote-state bucket (empty its versions before deleting), and the Route 53 ACM validation CNAME (removed by Terraform).
8. If using GitHub Actions: remove `AWS_ROLE_ARN`/secrets and the IAM role/OIDC provider if no longer needed.

### Destroy gotchas

- `DeletionProtection` error on RDS/ALB → step 3 was not applied first.
- `DependencyViolation` on subnet/SG/IGW → something outside Terraform (a manually-created ENI/endpoint/instance) is attached to the VPC; find with `aws ec2 describe-network-interfaces --filters Name=vpc-id,Values=<vpc>`.
- Destroy hangs on CloudFront: it must first be disabled and propagate (up to ~15–20 min). This is normal.
- ASG instance termination uses a 30 s target-group deregistration delay; allow a few minutes.
