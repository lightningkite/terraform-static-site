
variable "dist_folder" {
  type = string
}

resource "aws_s3_bucket" "files" {
  bucket_prefix = "web-${var.deployment_name}-files"
}
resource "aws_s3_bucket_public_access_block" "files" {
  bucket = aws_s3_bucket.files.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}
resource "aws_s3_bucket_policy" "files" {
  depends_on = [aws_s3_bucket_public_access_block.files]
  bucket     = aws_s3_bucket.files.id
  policy     = <<POLICY
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

module "template_files" {
  source  = "hashicorp/dir/template"
  version = "v1.0.2"

  base_dir = var.dist_folder
}

# robots.txt is uploaded directly as an S3 object rather than written into
# dist_folder, so it never mutates the directory scanned by template_files'
# fileset() call (which would otherwise produce an "inconsistent result" error).
resource "aws_s3_object" "robots-txt" {
  count         = var.create_robots_txt ? 1 : 0
  bucket        = aws_s3_bucket.files.id
  key           = "robots.txt"
  content       = "User-agent: *\nDisallow: /\nAllow: /.well-known/"
  content_type  = "text/plain"
  cache_control = "no-cache"
  etag          = md5("User-agent: *\nDisallow: /\nAllow: /.well-known/")
}

resource "aws_s3_object" "app_storage" {
  for_each = module.template_files.files
  bucket   = aws_s3_bucket.files.id
  key      = each.key

  content_type = (
    can(regex("\\.mjs$", each.value.source_path)) ? "application/javascript" :
    regex("[^\\/\\\\]+$", each.value.source_path) == "apple-app-site-association" ? "application/json" :
    each.value.content_type
  )

  # Cache-Control based on content hash detection:
  # - Files with hashes (e.g., index-D4kpuNiu.js) can be cached forever (immutable)
  # - Files without hashes should always revalidate (no-cache)
  # Using exact hash lengths for safety (no false positives)
  cache_control = (
    # Vite-style hashes: name-HASH.ext where HASH is exactly 8 base64url chars
    # e.g., index-D4kpuNiu.js - must contain at least one digit
    can(regex("-[a-zA-Z0-9]{8}\\.[a-zA-Z0-9]+$", each.value.source_path)) &&
    can(regex("-[a-zA-Z0-9]*[0-9][a-zA-Z0-9]*\\.", each.value.source_path))
    ? "max-age=31536000, immutable" :
    # Webpack-style hashes: name.HASH.ext where HASH is exactly 8 or 20 hex chars
    can(regex("\\.[a-f0-9]{8}\\.[a-zA-Z0-9]+$", each.value.source_path)) ||
    can(regex("\\.[a-f0-9]{20}\\.[a-zA-Z0-9]+$", each.value.source_path))
    ? "max-age=31536000, immutable" :
    # No hash detected - always revalidate to ensure fresh content
    "no-cache"
  )

  # The template_files module guarantees that only one of these two attributes
  # will be set for each file, depending on whether it is an in-memory template
  # rendering result or a static file on disk.
  source  = each.value.source_path
  content = each.value.content

  # Unless the bucket has encryption enabled, the ETag of each object is an
  # MD5 hash of that object.
  etag = each.value.digests.md5
}