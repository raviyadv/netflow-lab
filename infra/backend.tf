# Store this stack's state in S3 instead of on the laptop.
# Backend blocks cannot use variables, so values are written out here.
terraform {
  backend "s3" {
    bucket       = "netflow-lab-tfstate-099978877582" # created by ../bootstrap
    key          = "netflow-lab/infra.tfstate"        # path of the state file in the bucket
    region       = "ap-southeast-2"
    encrypt      = true
    use_lockfile = true # S3-native locking: blocks two applies running at once
  }
}
