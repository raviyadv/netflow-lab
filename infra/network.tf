# --- Look up what already exists (data sources create nothing) ---

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_route_tables" "default" {
  vpc_id = data.aws_vpc.default.id
}

# --- Create: S3 gateway endpoint (free) ---
# Lets the Lambda (inside the VPC, with no public IP) reach S3 privately,
# so we never need a NAT Gateway (~$0.045/hr + data charges).

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = data.aws_vpc.default.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = data.aws_route_tables.default.ids

  tags = {
    Name = "${var.project}-s3-endpoint"
  }
}
