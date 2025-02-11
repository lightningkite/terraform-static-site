
variable "dist_folder" {
  type = string
}

resource "aws_s3_bucket" "files" {
  bucket_prefix = "web-${var.deployment_name}-files"
}
resource "aws_s3_bucket_public_access_block" "files" {
  bucket = aws_s3_bucket.files.id

  block_public_acls   = false
  block_public_policy = false
  ignore_public_acls = false
  restrict_public_buckets = false
}
resource "aws_s3_bucket_policy" "files" {
  depends_on = [aws_s3_bucket_public_access_block.files]
  bucket = aws_s3_bucket.files.id
  policy = <<POLICY
{
    "Version": "2012-10-17",
    "Statement": [
      {
          "Sid": "PublicReadGetObject",
          "Effect": "Allow",
          "Principal": "*",
          "Action": [
             "s3:GetObject"
          ],
          "Resource": [
             "arn:aws:s3:::${aws_s3_bucket.files.id}/*"
          ]
      }
    ]
}
POLICY
}
resource "aws_s3_bucket_website_configuration" "files" {
  bucket = aws_s3_bucket.files.bucket
  index_document {
    suffix = "index.html"
  }
  error_document {
     key = "index.html"
#    key = "error.html"
  }
}
resource "aws_s3_bucket_cors_configuration" "files" {
  bucket = aws_s3_bucket.files.bucket

  cors_rule {
    allowed_methods = ["GET"]
    allowed_origins = ["*"]
  }
}

variable "create_robots_txt" {
  type    = bool
  default = true
}

resource "local_file" "robots-txt" {
  count = var.create_robots_txt ? 1 : 0
  content  = "User-agent: *\nDisallow: /"
  filename = "${var.dist_folder}/robots.txt"
}

module "template_files" {
  source = "hashicorp/dir/template"

  base_dir = var.dist_folder
  depends_on = [local_file.robots-txt]
}
locals {
  content_type_overrides = {
    "apple-app-site-association" = "application/json"
  }
}
resource "aws_s3_object" "app_storage" {
  for_each     = module.template_files.files
  bucket       = aws_s3_bucket.files.id
  key          = each.key
  content_type = lookup(local.content_type_overrides, regex("[^\\/\\\\]+$", each.value.source_path), each.value.content_type)

  # The template_files module guarantees that only one of these two attributes
  # will be set for each file, depending on whether it is an in-memory template
  # rendering result or a static file on disk.
  source  = each.value.source_path
  content = each.value.content

  # Unless the bucket has encryption enabled, the ETag of each object is an
  # MD5 hash of that object.
  etag = each.value.digests.md5
}