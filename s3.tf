
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

locals {
  content_type_overrides = {
    "apple-app-site-association" = "application/json"
  }
  # Taken from https://github.com/hashicorp/terraform-template-dir/blob/17b81de441645a94f4db1449fc8269cd32f26fde/variables.tf
  # with some additions for file types we need to support
  known_mime_types = {
    ".3g2"    : "video/3gpp2", 
    ".3gp"    : "video/3gpp", 
    ".atom"   : "application/atom+xml", 
    ".css"    : "text/css; charset=utf-8", 
    ".eot"    : "application/vnd.ms-fontobject", 
    ".gif"    : "image/gif", 
    ".htm"    : "text/html; charset=utf-8", 
    ".html"   : "text/html; charset=utf-8", 
    ".ico"    : "image/vnd.microsoft.icon", 
    ".jar"    : "application/java-archive", 
    ".jpeg"   : "image/jpeg", 
    ".jpg"    : "image/jpeg", 
    ".js"     : "application/javascript", 
    ".json"   : "application/json", 
    ".jsonld" : "application/ld+json", 
    ".otf"    : "font/otf", 
    ".pdf"    : "application/pdf", 
    ".png"    : "image/png", 
    ".rss"    : "application/rss+xml", 
    ".svg"    : "image/svg+xml", 
    ".swf"    : "application/x-shockwave-flash", 
    ".ttf"    : "font/ttf", 
    ".txt"    : "text/plain; charset=utf-8", 
    ".weba"   : "audio/webm", 
    ".webm"   : "video/webm", 
    ".webp"   : "image/webp", 
    ".woff"   : "font/woff", 
    ".woff2"  : "font/woff2", 
    ".xhtml"  : "application/xhtml+xml", 
    ".xml"    : "application/xml",
    ".wasm"   : "application/wasm"
  }
}
module "template_files" {
  source = "hashicorp/dir/template"

  base_dir   = var.dist_folder
  file_types = local.known_mime_types
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
