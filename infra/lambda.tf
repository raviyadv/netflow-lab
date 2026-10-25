# --- Execution role: what the Lambda itself is allowed to do ---
resource "aws_iam_role" "lambda" {
  name = "${var.project}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Write logs + create network interfaces in the VPC
resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# Least privilege: read objects from our bucket only
resource "aws_iam_role_policy" "lambda_s3" {
  name = "read-raw-bucket"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = "${aws_s3_bucket.raw.arn}/*"
    }]
  })
}

# --- Security group for the Lambda (outbound only) ---
resource "aws_security_group" "lambda" {
  name        = "${var.project}-lambda-sg"
  description = "Lambda: outbound to Kafka and S3 endpoint"
  vpc_id      = data.aws_vpc.default.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Create the log group ourselves so we control retention (and destroy removes it)
resource "aws_cloudwatch_log_group" "ingest" {
  name              = "/aws/lambda/${var.project}-ingest"
  retention_in_days = 3
}

# --- The function ---
resource "aws_lambda_function" "ingest" {
  function_name    = "${var.project}-ingest"
  role             = aws_iam_role.lambda.arn
  filename         = "${path.module}/../lambda/lambda.zip"
  source_code_hash = filebase64sha256("${path.module}/../lambda/lambda.zip")

  runtime       = "provided.al2023" # custom runtime: our Go binary named "bootstrap"
  handler       = "bootstrap"
  architectures = ["arm64"] # Graviton: cheaper and fast
  memory_size   = 256
  timeout       = 60

  environment {
    variables = {
      KAFKA_BROKERS = "${aws_instance.stack.private_ip}:9092"
      KAFKA_TOPIC   = "network-events"
    }
  }

  # Run inside the VPC so it can reach Kafka's private IP
  vpc_config {
    subnet_ids         = data.aws_subnets.default.ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  depends_on = [
    aws_cloudwatch_log_group.ingest,
    aws_iam_role_policy_attachment.lambda_vpc,
  ]
}

# --- Allow S3 to invoke the function (resource-based policy) ---
resource "aws_lambda_permission" "s3" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ingest.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.raw.arn
}

# --- Trigger: every new object under raw/ invokes the Lambda ---
resource "aws_s3_bucket_notification" "raw" {
  bucket = aws_s3_bucket.raw.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.ingest.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "raw/"
  }

  depends_on = [aws_lambda_permission.s3]
}

output "lambda_name" {
  value = aws_lambda_function.ingest.function_name
}
