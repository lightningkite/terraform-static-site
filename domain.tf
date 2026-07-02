variable "domain_name_zone" {
  type = string
}
variable "domain_name" {
  type = string
}
variable "content_security_policy" {
  type = map(list(string))
  default = {
    default-src : [
      "*",
      "'unsafe-eval'",
      "'wasm-unsafe-eval'",
      "'unsafe-inline'",
      "data:",
      "mediastream:",
      "blob:",
      "filesystem:",
      "about:",
      "ws:",
      "wss:",
    ]
    frame-src : [
      "*",
      "data:",
      "blob:",
    ]
    form-action : [
      "*"
    ]
    frame-ancestors : [
      "*",
      "data:",
      "blob:",
    ]
  }
}
variable "geo_restrictions_mode" {
  type    = string
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
  type    = list(string)
  default = []
}
variable "react_mode" {
  type    = bool
  default = false
}
variable "referrer_policy" {
  type    = string
  default = "same-origin"
}

data "aws_route53_zone" "main" {
  name = var.domain_name_zone
}

resource "aws_acm_certificate" "web" {
  provider          = aws.acm
  domain_name       = var.domain_name
  validation_method = "DNS"
  lifecycle { create_before_destroy = true }
}
resource "aws_route53_record" "web" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = tolist(aws_acm_certificate.web.domain_validation_options)[0].resource_record_name
  type    = tolist(aws_acm_certificate.web.domain_validation_options)[0].resource_record_type
  records = [tolist(aws_acm_certificate.web.domain_validation_options)[0].resource_record_value]
  ttl     = "300"
}
resource "aws_acm_certificate_validation" "web" {
  provider                = aws.acm
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

# Cache policy for the static site. Replaces the legacy `forwarded_values` block:
# cookies are never forwarded (they only fragment the cache on a static site),
# while query strings remain in the cache key to preserve cache-busting behavior.
# TTLs bound the origin's Cache-Control (min_ttl=0 lets index.html stay no-cache;
# max_ttl allows immutable hashed assets to cache for a year).
resource "aws_cloudfront_cache_policy" "static" {
  name        = "static-cache-${replace(var.domain_name, "/[^a-zA-Z0-9\\-]/", "-")}"
  min_ttl     = 0
  default_ttl = 86400
  max_ttl     = 31536000

  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config {
      cookie_behavior = "none"
    }
    headers_config {
      header_behavior = "none"
    }
    query_strings_config {
      query_string_behavior = "all"
    }
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true
  }
}
resource "aws_cloudfront_distribution" "main" {
  depends_on          = [aws_s3_bucket.files]
  enabled             = true
  aliases             = [var.domain_name]
  default_root_object = "index.html"

  origin {
    domain_name = aws_s3_bucket_website_configuration.files.website_endpoint
    origin_id   = "origin-${var.domain_name}"
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }
  default_cache_behavior {
    allowed_methods            = ["GET", "HEAD", "OPTIONS"]
    cached_methods             = ["GET", "HEAD", "OPTIONS"]
    target_origin_id           = "origin-${var.domain_name}"
    viewer_protocol_policy     = "redirect-to-https" # other options - https only, http
    response_headers_policy_id = aws_cloudfront_response_headers_policy.webapp_security_headers.id
    cache_policy_id            = aws_cloudfront_cache_policy.static.id

    dynamic "lambda_function_association" {
      for_each = length(aws_lambda_function.edge_lambda) > 0 ? [1] : []
      content {
        event_type   = "origin-response"
        lambda_arn   = aws_lambda_function.edge_lambda[0].qualified_arn
        include_body = false
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
      locations        = var.geo_restrictions_list
    }
  }

  viewer_certificate {
    # Reference the validation resource (not the certificate directly) so the
    # distribution is not created until DNS validation has completed.
    acm_certificate_arn      = aws_acm_certificate_validation.web.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

resource "aws_cloudfront_response_headers_policy" "webapp_security_headers" {
  name = "webapp-security-headers-${replace(var.domain_name, "/[^a-zA-Z0-9\\-]/", "-")}"
  security_headers_config {
    content_type_options {
      override = true
    }
    frame_options {
      frame_option = "DENY"
      override     = true
    }
    referrer_policy {
      referrer_policy = var.referrer_policy
      override        = true
    }
    xss_protection {
      mode_block = true
      protection = true
      override   = true
    }
    strict_transport_security {
      access_control_max_age_sec = "63072000"
      include_subdomains         = true
      preload                    = true
      override                   = true
    }
    content_security_policy {
      content_security_policy = join("; ", [
        for key, value in var.content_security_policy : "${key} ${join(" ", value)}"
      ])
      #       content_security_policy = "frame-ancestors 'self'; default-src 'self'; img-src ${var.external_media_sources}; media-src ${var.external_media_sources}; script-src 'self' ${var.external_script_sources}; style-src 'self' 'unsafe-inline'; object-src 'none'; connect-src ${var.external_connections}"
      override = true
    }
  }
}

# Invalidate CloudFront cache after S3 files are updated
# This ensures users get fresh content immediately after deployment
resource "terraform_data" "cloudfront_invalidation" {
  # Trigger invalidation when source files change (computed before upload, so stable during plan)
  triggers_replace = {
    files_hash = md5(join(",", [for k, v in module.template_files.files : v.digests.md5]))
  }

  # Ensure S3 uploads complete before invalidation
  depends_on = [aws_s3_object.app_storage]

  provisioner "local-exec" {
    command = "aws cloudfront create-invalidation --distribution-id ${aws_cloudfront_distribution.main.id} --paths '/*'"
  }
}
