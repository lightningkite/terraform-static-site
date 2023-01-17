
variable "domain_name_zone" {
}
variable "domain_name" {
}
variable "geo_restrictions_mode" {
  type = string
  default = "none"
  validation {
    condition = contains([
      "none",
      "whitelist",
      "blacklist",
    ], var.geo_restrictions_mode)
    error_message = "Must be one of none, whitelist, blacklist"
  }
}
variable "geo_restrictions_list" {
  type = list(string)
  default = []
}
variable "react_mode" {
  type = bool
  default = false
}

data "aws_route53_zone" "main" {
  name = var.domain_name_zone
}

resource "aws_acm_certificate" "web" {
  provider = aws.acm
  domain_name       = var.domain_name
  validation_method = "DNS"
}
resource "aws_route53_record" "web" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = tolist(aws_acm_certificate.web.domain_validation_options)[0].resource_record_name
  type    = tolist(aws_acm_certificate.web.domain_validation_options)[0].resource_record_type
  records = [tolist(aws_acm_certificate.web.domain_validation_options)[0].resource_record_value]
  ttl     = "300"
}
resource "aws_acm_certificate_validation" "web" {
  provider = aws.acm
  certificate_arn         = aws_acm_certificate.web.arn
  validation_record_fqdns = [aws_route53_record.web.fqdn]
}
resource "aws_route53_record" "web_cloudfront" {
  name    = var.domain_name
  zone_id = data.aws_route53_zone.main.zone_id
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.main.domain_name
    zone_id                = aws_cloudfront_distribution.main.hosted_zone_id
    evaluate_target_health = true
  }
}


resource "aws_cloudfront_origin_access_identity" "oai" {
  comment = "OAI for ${var.domain_name}"
}
resource "aws_cloudfront_distribution" "main" {
  enabled             = true
  aliases             = [var.domain_name]
  default_root_object = "index.html"

  origin {
    domain_name = aws_s3_bucket.files.bucket_regional_domain_name
    origin_id   = aws_s3_bucket.files.id

    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.oai.cloudfront_access_identity_path
    }
  }
  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD", "OPTIONS"]
    target_origin_id       = aws_s3_bucket.files.id
    viewer_protocol_policy = "redirect-to-https" # other options - https only, http

    forwarded_values {
      headers      = []
      query_string = true

      cookies {
        forward = "all"
      }
    }

  }

  dynamic "custom_error_response" {
    for_each = var.react_mode ? [403, 404] : []
    content {
      error_caching_min_ttl = 300
      error_code            = custom_error_response.value
      response_code         = 200
      response_page_path    = "/index.html"
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = var.geo_restrictions_mode
      locations = var.geo_restrictions_list
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate.web.arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2018"
  }
}