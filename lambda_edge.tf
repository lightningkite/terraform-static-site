

variable "lambda_src_dir" {
  type    = string
  default = null
}
variable "lambda_dist_dir" {
  type    = string
  default = null
}

# zip lambda code
data "archive_file" "lambda_zip" {
  count       = var.lambda_src_dir != null ? 1 : 0
  type        = "zip"
  source_dir  = var.lambda_src_dir # contains index.js + package.json
  output_path = coalesce(var.lambda_dist_dir, "${var.lambda_src_dir}/../lambda.zip")
}

resource "aws_iam_role" "lambda_edge_role" {
  count = var.lambda_src_dir != null ? 1 : 0
  name_prefix  = "lambda_edge_execution_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = {
        Service = [
          "lambda.amazonaws.com",
          "edgelambda.amazonaws.com"
        ]
      },
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  count      = var.lambda_src_dir != null ? 1 : 0
  role       = aws_iam_role.lambda_edge_role[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
resource "aws_iam_role_policy_attachment" "s3_readonly" {
  count      = var.lambda_src_dir != null ? 1 : 0
  role       = aws_iam_role.lambda_edge_role[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
}

resource "aws_lambda_function" "edge_lambda" {
  count         = var.lambda_src_dir != null ? 1 : 0
  provider      = aws.acm
  function_name = "${var.deployment_name}-AddOGTags"
  role          = aws_iam_role.lambda_edge_role[0].arn
  handler       = "index.handler"
  runtime       = "nodejs22.x"

  filename         = data.archive_file.lambda_zip[0].output_path
  source_code_hash = data.archive_file.lambda_zip[0].output_base64sha256

  timeout = 5
  publish = true

  lifecycle {
    prevent_destroy = false
    create_before_destroy = true
  }
}
