
variable "domain_name_zone" {
}
variable "domain_name" {
}
variable "external_script_sources" {
  type = string
  default = ""
}
variable "external_media_sources" {
  type = string
  default = "*"
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
  depends_on = [aws_s3_bucket.files]
  enabled             = true
  aliases             = [var.domain_name]
  default_root_object = "index.html"

  origin {
    domain_name = aws_s3_bucket.files.website_endpoint
    origin_id   = "origin-${var.domain_name}"
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols = ["TLSv1"]
    }
  }
  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD", "OPTIONS"]
    target_origin_id       = "origin-${var.domain_name}"
    viewer_protocol_policy = "redirect-to-https" # other options - https only, http
    response_headers_policy_id = aws_cloudfront_response_headers_policy.webapp_security_headers

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

resource "aws_cloudfront_response_headers_policy" "webapp_security_headers" {
  name = "webapp-security-headers"
  security_headers_config {
    content_type_options {
      override = true
    }
    frame_options {
      frame_option = "DENY"
      override = true
    }
    referrer_policy {
      referrer_policy = "same-origin"
      override = true
    }
    xss_protection {
      mode_block = true
      protection = true
      override = true
    }
    strict_transport_security {
      access_control_max_age_sec = "63072000"
      include_subdomains = true
      preload = true
      override = true
    }
    content_security_policy {
      content_security_policy = "frame-ancestors 'self'; default-src 'self'; img-src ${var.external_media_sources}; media-src ${var.external_media_sources}; script-src 'self' ${var.external_script_sources}; style-src 'self'; object-src 'none'"
      override = true
    }
  }
}