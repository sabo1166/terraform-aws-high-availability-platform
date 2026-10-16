# Troubleshooting (AWS CLI)

All commands are read-only. None print secret values (the database secret is referenced by ARN only; never run `get-secret-value` in a shared terminal).
Set once: `export AWS_REGION=us-east-1 P=ha-web-lab` (PowerShell: `$env:AWS_REGION="us-east-1"; $P="ha-web-lab"`). Names below follow `<project>-<environment>`.

## 0. Which credentials am I using?
```bash
aws sts get-caller-identity
```
`InvalidClientTokenId` / `AuthFailure` = bad or expired keys; fix before anything else.

## 1. AMI
```bash
aws ec2 describe-images --region us-east-1 --image-ids ami-0ed59cbb87dfa8dba \
  --query 'Images[0].[ImageId,Name,Architecture,PlatformDetails,State,OwnerId,RootDeviceName,RootDeviceType,Description]' --output table
# Which instance types support its architecture?
aws ec2 describe-instance-types --instance-types t3.micro t4g.micro \
  --query 'InstanceTypes[].[InstanceType,ProcessorInfo.SupportedArchitectures[0]]' --output table
```
Empty/`InvalidAMIID.NotFound` → the AMI does not exist or is not shared with this account in us-east-1.

## 2. Auto Scaling groups
```bash
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $P-frontend $P-backend \
  --query 'AutoScalingGroups[].[AutoScalingGroupName,DesiredCapacity,MinSize,MaxSize,Instances[].[InstanceId,AvailabilityZone,LifecycleState,HealthStatus]]'
aws autoscaling describe-scaling-activities --auto-scaling-group-name $P-frontend --max-items 15 \
  --query 'Activities[].[StartTime,StatusCode,Description,StatusMessage]' --output table
aws autoscaling describe-instance-refreshes --auto-scaling-group-name $P-frontend
aws autoscaling describe-policies --auto-scaling-group-name $P-backend
```
Launch failures (`StatusMessage`) usually mean: AMI/instance-type architecture mismatch, no capacity, or encrypted-volume KMS permissions.

## 3. EC2 status checks & instance logs
```bash
aws ec2 describe-instance-status --include-all-instances \
  --filters Name=tag:Project,Values=ha-web \
  --query 'InstanceStatuses[].[InstanceId,AvailabilityZone,InstanceState.Name,InstanceStatus.Status,SystemStatus.Status]' --output table
aws ec2 get-console-output --instance-id <i-id> --latest --output text | tail -n 80   # cloud-init output
# Shell on an instance (no SSH): requires the Session Manager plugin
aws ssm describe-instance-information --query 'InstanceInformationList[].[InstanceId,PingStatus,PlatformName]' --output table
aws ssm start-session --target <i-id>
#   then:  sudo tail -n 100 /var/log/app-bootstrap.log ; systemctl status nginx app ; curl -s localhost/healthz  (frontend) / localhost:8080/health (backend)
```
`PingStatus` missing → instance has no route to SSM (check NAT / route table) or the role lacks `AmazonSSMManagedInstanceCore`.

## 4. Target group health
```bash
FE=$(aws elbv2 describe-target-groups --names $P-fe-tg --query 'TargetGroups[0].TargetGroupArn' --output text)
BE=$(aws elbv2 describe-target-groups --names $P-be-tg --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 describe-target-health --target-group-arn $FE --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Reason,TargetHealth.Description]' --output table
aws elbv2 describe-target-health --target-group-arn $BE --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Reason,TargetHealth.Description]' --output table
aws elbv2 describe-target-groups --target-group-arns $FE $BE --query 'TargetGroups[].[TargetGroupName,HealthCheckPath,HealthCheckPort,Matcher.HttpCode]' --output table
```
`Target.FailedHealthChecks` → bootstrap failed or SG blocks the ALB → instance port. `Target.Timeout` → SG/route. `Target.ResponseCodeMismatch` → app up but wrong path/code.

## 5. ALB, listeners, rules
```bash
aws elbv2 describe-load-balancers --names $P-ext-alb $P-int-alb --query 'LoadBalancers[].[LoadBalancerName,Scheme,State.Code,DNSName]' --output table
EXT=$(aws elbv2 describe-load-balancers --names $P-ext-alb --query 'LoadBalancers[0].LoadBalancerArn' --output text)
aws elbv2 describe-listeners --load-balancer-arn $EXT --query 'Listeners[].[ListenerArn,Port,Protocol,DefaultActions[0].Type]' --output table
LST=$(aws elbv2 describe-listeners --load-balancer-arn $EXT --query 'Listeners[0].ListenerArn' --output text)
aws elbv2 describe-rules --listener-arn $LST --query 'Rules[].[Priority,Conditions[0].Field,Actions[0].Type]' --output table
```
(The rule's header **value** is deliberately not selected above.) Direct `curl http://<ext-alb-dns>/` should return **403**; if CloudFront also returns 403, the CloudFront header and ALB rule values differ (re-apply).

## 6. CloudFront
```bash
aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='$P web platform'].[Id,DomainName,Status,Aliases.Items]" --output table
aws cloudfront get-distribution --id <ID> --query 'Distribution.[Status,DistributionConfig.ViewerCertificate.ACMCertificateArn,DistributionConfig.Aliases.Items]'
aws cloudfront list-invalidations --distribution-id <ID>
aws cloudfront create-invalidation --distribution-id <ID> --paths '/static/*'
curl -sI https://<domain>/ | head -n 15      # check x-cache, via, status
curl -sI http://<domain>/ | head -n 5        # expect 301 → https
```
`Status: InProgress` = still deploying (up to ~15 min). 502/504 → origin unhealthy or unreachable; 403 → origin-header mismatch.

## 7. ACM
```bash
aws acm list-certificates --region us-east-1 --query 'CertificateSummaryList[].[DomainName,Status,CertificateArn]' --output table
aws acm describe-certificate --region us-east-1 --certificate-arn <ARN> \
  --query 'Certificate.[Status,FailureReason,DomainValidationOptions[].[DomainName,ValidationStatus,ResourceRecord]]'
```
`PENDING_VALIDATION` for long → the CNAME is not resolvable publicly: wrong hosted zone, or the domain's registrar NS records don't point to this Route 53 zone (see §8).

## 8. Route 53
```bash
aws route53 list-hosted-zones-by-name --dns-name example.com --query 'HostedZones[].[Id,Name,Config.PrivateZone]'
aws route53 list-resource-record-sets --hosted-zone-id <ZONE_ID> \
  --query "ResourceRecordSets[?Type=='A'||Type=='AAAA'||Type=='CNAME'].[Name,Type,AliasTarget.DNSName]" --output table
aws route53 get-hosted-zone --id <ZONE_ID> --query 'DelegationSet.NameServers'   # must match the registrar's NS records
nslookup -type=NS example.com ; nslookup app.example.com
```

## 9. RDS
```bash
aws rds describe-db-instances --db-instance-identifier $P-postgres \
  --query 'DBInstances[0].[DBInstanceStatus,MultiAZ,PubliclyAccessible,StorageEncrypted,EngineVersion,AvailabilityZone,SecondaryAvailabilityZone,DeletionProtection,BackupRetentionPeriod,Endpoint.Address]'
aws rds describe-events --source-type db-instance --source-identifier $P-postgres --duration 1440 \
  --query 'Events[].[Date,Message]' --output table
aws rds describe-db-log-files --db-instance-identifier $P-postgres
aws rds describe-db-instances --db-instance-identifier $P-postgres --query 'DBInstances[0].MasterUserSecret.[SecretArn,SecretStatus]'   # ARN only
```
From a backend instance (SSM session): `curl -s localhost:8080/api/db-health`. `db_tcp_reachable:false` → check the rds/backend SG rules and that the instance is in the app subnets.

## 10. CloudWatch logs & alarms
```bash
aws logs describe-log-groups --log-group-name-prefix "/$P" --query 'logGroups[].logGroupName'
aws logs describe-log-groups --log-group-name-prefix "/aws/rds/instance/$P" --query 'logGroups[].logGroupName'
aws logs tail "/$P/vpc-flow-logs" --since 15m | grep REJECT | head -n 20
aws logs tail "/aws/rds/instance/$P-postgres/postgresql" --since 1h
aws cloudwatch describe-alarms --alarm-name-prefix $P --query 'MetricAlarms[].[AlarmName,StateValue,StateReason]' --output table
```

## 11. Network sanity
```bash
VPC=$(aws ec2 describe-vpcs --filters Name=tag:Name,Values=$P-vpc --query 'Vpcs[0].VpcId' --output text)
aws ec2 describe-nat-gateways --filter Name=vpc-id,Values=$VPC --query 'NatGateways[].[NatGatewayId,State,SubnetId]' --output table
aws ec2 describe-route-tables --filters Name=vpc-id,Values=$VPC \
  --query 'RouteTables[].[Tags[?Key==`Name`]|[0].Value,Routes[].[DestinationCidrBlock,NatGatewayId,GatewayId]]'
aws ec2 describe-security-groups --filters Name=vpc-id,Values=$VPC --query 'SecurityGroups[].[GroupName,GroupId]' --output table
```
The `*-rt-db-isolated` table must show only the `local` route.

## Terraform-level
```bash
terraform validate && terraform plan          # preflight/AMI errors surface here, with explanatory messages
terraform state list | head -n 50
terraform force-unlock <LOCK_ID>              # only if a crashed run left a stale lock
# Remote state problems (bucket checks, stale locks, restoring a version, migrating state): docs/REMOTE_STATE.md
aws s3api get-bucket-versioning --bucket <STATE_BUCKET>
aws s3api list-object-versions --bucket <STATE_BUCKET> --prefix ha-web/lab/
```
