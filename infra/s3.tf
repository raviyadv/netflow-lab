data "aws_caller_identity" "current" {}

# Raw network data lands here. Bucket names are globally unique,
# so we append the account ID.
resource "aws_s3_bucket" "raw" {
  bucket = "${var.project}-raw-${data.aws_caller_identity.current.account_id}"

  # Lets `terraform destroy` delete the bucket even if it still has files.
  # Fine for a lab; never do this for production data.
  force_destroy = true
}

# Make sure nothing in this bucket can ever be made public.
resource "aws_s3_bucket_public_access_block" "raw" {
  bucket = aws_s3_bucket.raw.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
