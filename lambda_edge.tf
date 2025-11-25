

variable "lambda_src_dir" {
  type = string
}

# zip lambda code
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = var.lambda_src_dir # contains index.js + package.json
  output_path = "./lambda.zip"
}

resource "aws_iam_role" "lambda_edge_role" {
  name = "lambda_edge_execution_role"

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
  role       = aws_iam_role.lambda_edge_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
resource "aws_iam_role_policy_attachment" "s3_readonly" {
  role       = aws_iam_role.lambda_edge_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
}

resource "aws_lambda_function" "edge_lambda" {
  provider = aws.east
  function_name = "AddOGTags"
  role          = aws_iam_role.lambda_edge_role.arn
  handler       = "index.handler"
  runtime       = "nodejs22.x"

  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  timeout = 5

  # Publish on creation/change
  publish = true
}
