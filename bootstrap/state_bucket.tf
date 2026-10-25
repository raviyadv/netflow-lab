# Bucket that stores Terraform state for the main infra stack.
resource "aws_s3_bucket" "tfstate" {
  bucket = "netflow-lab-tfstate-${data.aws_caller_identity.current.account_id}"

  # Losing state = Terraform forgets what it built. Block accidental deletion.
  lifecycle {
    prevent_destroy = true
  }
}

# Keep every previous version of the state file -> recover from mistakes.
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Encrypt state at rest (it can contain sensitive values).
resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

output "state_bucket" {
  value = aws_s3_bucket.tfstate.bucket
}
