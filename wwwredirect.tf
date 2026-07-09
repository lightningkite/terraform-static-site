variable "enable_www_redirect" {
  type    = bool
  default = true
}

resource "aws_s3_bucket" "www" {
  count  = var.enable_www_redirect ? 1 : 0
  bucket = "www.${var.domain_name}"
}
resource "aws_s3_bucket_public_access_block" "www" {
  count  = var.enable_www_redirect ? 1 : 0
  bucket = aws_s3_bucket.www[0].id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}
resource "aws_s3_bucket_policy" "www" {
  count      = var.enable_www_redirect ? 1 : 0
  depends_on = [aws_s3_bucket_public_access_block.www]
  bucket     = aws_s3_bucket.www[0].id
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
             "arn:aws:s3:::${aws_s3_bucket.www[0].id}/*"
          ]
      }
    ]
}
POLICY
}

resource "aws_s3_bucket_website_configuration" "www" {
  count  = var.enable_www_redirect ? 1 : 0
  bucket = aws_s3_bucket.www[0].bucket
  redirect_all_requests_to {
    host_name = var.domain_name
  }
}

resource "aws_acm_certificate" "www" {
  count             = var.enable_www_redirect ? 1 : 0
  provider          = aws.acm
  domain_name       = "www.${var.domain_name}"
  validation_method = "DNS"
  lifecycle { create_before_destroy = true }
}
resource "aws_route53_record" "www" {
  count   = var.enable_www_redirect ? 1 : 0
  zone_id = data.aws_route53_zone.main.zone_id
  name    = tolist(aws_acm_certificate.www[0].domain_validation_options)[0].resource_record_name
  type    = tolist(aws_acm_certificate.www[0].domain_validation_options)[0].resource_record_type
  records = [tolist(aws_acm_certificate.www[0].domain_validation_options)[0].resource_record_value]
  ttl     = "300"
}
resource "aws_acm_certificate_validation" "www" {
  count                   = var.enable_www_redirect ? 1 : 0
  provider                = aws.acm
  certificate_arn         = aws_acm_certificate.www[0].arn
  validation_record_fqdns = [aws_route53_record.www[0].fqdn]
}
resource "aws_route53_record" "www_cloudfront" {
  count   = var.enable_www_redirect ? 1 : 0
  name    = "www.${var.domain_name}"
  zone_id = data.aws_route53_zone.main.zone_id
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.www[0].domain_name
    zone_id                = aws_cloudfront_distribution.www[0].hosted_zone_id
    evaluate_target_health = true
  }
}
resource "aws_route53_record" "www_cloudfront_ipv6" {
  count   = var.enable_www_redirect ? 1 : 0
  name    = "www.${var.domain_name}"
  zone_id = data.aws_route53_zone.main.zone_id
  type    = "AAAA"

  alias {
    name                   = aws_cloudfront_distribution.www[0].domain_name
    zone_id                = aws_cloudfront_distribution.www[0].hosted_zone_id
    evaluate_target_health = true
  }
}


resource "aws_cloudfront_distribution" "www" {
  count           = var.enable_www_redirect ? 1 : 0
  enabled         = true
  is_ipv6_enabled = var.enable_ipv6
  aliases         = ["www.${var.domain_name}"]
  depends_on      = [aws_s3_bucket.www]

  origin {
    connection_attempts = 3
    connection_timeout  = 10
    domain_name         = aws_s3_bucket_website_configuration.www[0].website_endpoint
    origin_id           = aws_s3_bucket.www[0].id

    custom_origin_config {
      http_port                = 80
      https_port               = 443
      origin_keepalive_timeout = 5
      origin_protocol_policy   = "http-only"
      origin_read_timeout      = 30
      origin_ssl_protocols     = ["TLSv1.2"]
    }

  }
  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD", "OPTIONS"]
    target_origin_id       = aws_s3_bucket.www[0].id
    viewer_protocol_policy = "redirect-to-https" # other options - https only, http
    cache_policy_id        = aws_cloudfront_cache_policy.static.id
  }

  restrictions {
    geo_restriction {
      restriction_type = var.geo_restrictions_mode
      locations        = var.geo_restrictions_list
    }
  }

  viewer_certificate {
    # Reference the validation resource (not the certificate directly) so the
    # distribution is not created until DNS validation has completed.
    acm_certificate_arn      = aws_acm_certificate_validation.www[0].certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}
