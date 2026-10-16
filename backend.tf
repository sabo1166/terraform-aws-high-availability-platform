# Remote state: S3 with native lockfile locking (Terraform >= 1.10; DynamoDB locking is deprecated).
#
# This is a PARTIAL configuration. Backend blocks cannot reference variables, and no bucket name is
# committed, so bucket, key and region are supplied at init time:
#
#   terraform init -backend-config=backend.tfbackend        # copy backend.tfbackend.example first
#
# CI does the same through .github/actions/terraform-backend. Bootstrapping the bucket, the IAM
# permissions, migrating existing state and recovery: docs/REMOTE_STATE.md.
#
# Not using a remote backend (throwaway experiments only)? Create an untracked override.tf containing
#   terraform { backend "local" {} }
# Never run CI or share a stack on local state.
terraform {
  backend "s3" {
    encrypt      = true # server-side encryption of the state object
    use_lockfile = true # lock object "<key>.tflock" in the same bucket; needs no DynamoDB table
  }
}
