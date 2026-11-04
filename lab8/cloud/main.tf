# Lab 8, Part 4: payments streamed through the cloud.
#
#   producer (laptop) -> Kinesis Data Streams (on-demand)
#                          |-> Data Firehose (60 s buffer) -> S3 payments-stream/dt=.../
#                          |                                   -> Glue Crawler -> Athena
#                          '-> Lambda (failure share per method) -> SNS -> e-mail
#
# Local state on purpose: this stack lives for one evening and is destroyed after
# (a Kinesis stream is billed by the hour). It is not part of the HCP workspace.
#
#   terraform -chdir=lab8/cloud init
#   terraform -chdir=lab8/cloud apply -var alert_email=you@example.com
#   ...
#   terraform -chdir=lab8/cloud destroy -var alert_email=you@example.com

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      PROJECT_NAME = "spry"
      Lab          = "8"
      ManagedBy    = "terraform"
    }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "bucket" {
  description = "Our own bucket from Part 2; the stream lands under payments-stream/."
  type        = string
  default     = "spry-lab8-416670858269"
}

variable "alert_email" {
  description = "Where SNS sends the failure alerts (confirm the subscription e-mail)."
  type        = string
}

variable "threshold" {
  type    = number
  default = 0.10
}

data "aws_s3_bucket" "lake" {
  bucket = var.bucket
}

# ---------------------------------------------------------------- the stream
resource "aws_kinesis_stream" "payments" {
  name             = "lab8-payments"
  retention_period = 24

  stream_mode_details {
    stream_mode = "ON_DEMAND"
  }
}

# ---------------------------------------------------------------- Firehose -> S3
data "aws_iam_policy_document" "firehose_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["firehose.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "firehose" {
  name               = "lab8-firehose"
  assume_role_policy = data.aws_iam_policy_document.firehose_trust.json
}

data "aws_iam_policy_document" "firehose" {
  statement {
    actions = [
      "kinesis:DescribeStream",
      "kinesis:DescribeStreamSummary",
      "kinesis:GetShardIterator",
      "kinesis:GetRecords",
      "kinesis:ListShards",
    ]
    resources = [aws_kinesis_stream.payments.arn]
  }
  statement {
    actions = [
      "s3:AbortMultipartUpload",
      "s3:GetBucketLocation",
      "s3:GetObject",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
      "s3:PutObject",
    ]
    resources = [data.aws_s3_bucket.lake.arn, "${data.aws_s3_bucket.lake.arn}/*"]
  }
}

resource "aws_iam_role_policy" "firehose" {
  name   = "read-stream-write-s3"
  role   = aws_iam_role.firehose.id
  policy = data.aws_iam_policy_document.firehose.json
}

resource "aws_kinesis_firehose_delivery_stream" "payments" {
  name        = "lab8-payments-to-s3"
  destination = "extended_s3"

  kinesis_source_configuration {
    kinesis_stream_arn = aws_kinesis_stream.payments.arn
    role_arn           = aws_iam_role.firehose.arn
  }

  extended_s3_configuration {
    role_arn   = aws_iam_role.firehose.arn
    bucket_arn = data.aws_s3_bucket.lake.arn
    # Hive-style dt=... folders, so the crawler sees a partition, like in Part 2.
    prefix              = "payments-stream/dt=!{timestamp:yyyy-MM-dd}/"
    error_output_prefix = "payments-stream-errors/!{firehose:error-output-type}/dt=!{timestamp:yyyy-MM-dd}/"
    buffering_interval  = 60
    buffering_size      = 5
  }

  depends_on = [aws_iam_role_policy.firehose]
}

# ---------------------------------------------------------------- alerts: Lambda -> SNS
resource "aws_sns_topic" "alerts" {
  name = "lab8-failure-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "alert" {
  name               = "lab8-failure-alert"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

# Read the stream + write logs.
resource "aws_iam_role_policy_attachment" "alert_kinesis" {
  role       = aws_iam_role.alert.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaKinesisExecutionRole"
}

resource "aws_iam_role_policy" "alert_sns" {
  name = "publish-alerts"
  role = aws_iam_role.alert.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sns:Publish", Resource = aws_sns_topic.alerts.arn }]
  })
}

data "archive_file" "alert" {
  type        = "zip"
  source_file = "${path.module}/lambda/alert.py"
  output_path = "${path.module}/build/alert.zip"
}

resource "aws_cloudwatch_log_group" "alert" {
  name              = "/aws/lambda/lab8-failure-alert"
  retention_in_days = 7
}

resource "aws_lambda_function" "alert" {
  function_name    = "lab8-failure-alert"
  role             = aws_iam_role.alert.arn
  runtime          = "python3.13"
  handler          = "alert.handler"
  filename         = data.archive_file.alert.output_path
  source_code_hash = data.archive_file.alert.output_base64sha256
  timeout          = 60
  memory_size      = 256

  environment {
    variables = {
      TOPIC_ARN    = aws_sns_topic.alerts.arn
      THRESHOLD    = tostring(var.threshold)
      MIN_FINISHED = "20"
    }
  }

  depends_on = [aws_cloudwatch_log_group.alert, aws_iam_role_policy_attachment.alert_kinesis]
}

# Up to 10 000 records or 60 s per call: at most about one check (and one e-mail) a minute.
resource "aws_lambda_event_source_mapping" "alert" {
  event_source_arn                   = aws_kinesis_stream.payments.arn
  function_name                      = aws_lambda_function.alert.arn
  starting_position                  = "LATEST"
  batch_size                         = 10000
  maximum_batching_window_in_seconds = 60
}

# ---------------------------------------------------------------- Glue Crawler -> Athena
resource "aws_glue_catalog_database" "stream" {
  name = "lab8_stream"
}

data "aws_iam_policy_document" "glue_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "glue" {
  name               = "lab8-glue-crawler"
  assume_role_policy = data.aws_iam_policy_document.glue_trust.json
}

resource "aws_iam_role_policy_attachment" "glue_service" {
  role       = aws_iam_role.glue.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_role_policy" "glue_s3" {
  name = "read-payments-stream"
  role = aws_iam_role.glue.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:ListBucket"], Resource = data.aws_s3_bucket.lake.arn },
      { Effect = "Allow", Action = ["s3:GetObject"], Resource = "${data.aws_s3_bucket.lake.arn}/payments-stream/*" },
    ]
  })
}

resource "aws_glue_crawler" "stream" {
  name          = "lab8-payments-stream"
  database_name = aws_glue_catalog_database.stream.name
  role          = aws_iam_role.glue.arn

  s3_target {
    path = "s3://${var.bucket}/payments-stream/"
  }
}

# ---------------------------------------------------------------- outputs
output "stream_name" {
  value = aws_kinesis_stream.payments.name
}

output "firehose_name" {
  value = aws_kinesis_firehose_delivery_stream.payments.name
}

output "crawler_name" {
  value = aws_glue_crawler.stream.name
}

output "s3_prefix" {
  value = "s3://${var.bucket}/payments-stream/"
}
