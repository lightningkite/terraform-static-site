# terraform-static-site

A Terraform module for deploying a static website on AWS using **S3**, **CloudFront**, **Route 53**, and **ACM**, with optional **Lambda@Edge** support.

## Features

- **S3-hosted static site** with CloudFront CDN in front
- **HTTPS** via ACM certificate with automatic DNS validation
- **www redirect** — `www.example.com` → `example.com`
- **Smart cache control** — content-hashed assets (Vite/Webpack) get immutable caching; unhashed files always revalidate
- **Automatic CloudFront invalidation** on deploy
- **Security headers** — CSP, HSTS, X-Content-Type-Options, X-Frame-Options, XSS-Protection, Referrer-Policy
- **React/SPA mode** — optional 403/404 → `index.html` rewrite for client-side routing
- **Geo-restrictions** — optional whitelist/blacklist by country
- **Lambda@Edge** — optional origin-response function (e.g., for injecting OG tags)
- **robots.txt** — auto-generated disallow-all by default

## Usage

```hcl
module "static_site" {
  source = "github.com/lightningkite/terraform-static-site"

  providers = {
    aws     = aws
    aws.acm = aws.us_east_1  # ACM certs for CloudFront must be in us-east-1
  }

  deployment_name      = "my-app"
  deployment_location  = "us-west-2"
  domain_name_zone     = "example.com"
  domain_name          = "app.example.com"
  dist_folder          = "${path.module}/dist"
  react_mode           = true
}
```

### With Lambda@Edge

```hcl
module "static_site" {
  source = "github.com/lightningkite/terraform-static-site"

  providers = {
    aws     = aws
    aws.acm = aws.us_east_1
  }

  deployment_name      = "my-app"
  domain_name_zone     = "example.com"
  domain_name          = "app.example.com"
  dist_folder          = "${path.module}/dist"
  react_mode           = true
  lambda_src_dir       = "${path.module}/lambda"
}
```

## Required Providers

This module requires **two** AWS provider configurations:

| Provider   | Purpose                                          |
|------------|--------------------------------------------------|
| `aws`      | Primary provider for S3, Route 53, etc.          |
| `aws.acm`  | Must be in `us-east-1` for CloudFront ACM certs and Lambda@Edge |

```hcl
provider "aws" {
  region = "us-west-2"
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}
```

## Variables

### Required

| Variable            | Type     | Description                                |
|---------------------|----------|--------------------------------------------|
| `deployment_name`   | `string` | Name prefix for resources (S3 buckets, Lambda, etc.) |
| `domain_name_zone`  | `string` | Route 53 hosted zone name (e.g., `example.com`) |
| `domain_name`       | `string` | Full domain for the site (e.g., `app.example.com`) |
| `dist_folder`       | `string` | Path to the local build output directory to upload |

### Optional

| Variable                  | Type                  | Default        | Description |
|---------------------------|-----------------------|----------------|-------------|
| `deployment_location`     | `string`              | `"us-west-2"`  | AWS region for the deployment |
| `react_mode`              | `bool`                | `false`        | Enable SPA fallback (rewrites 403/404 to `/index.html`) |
| `content_security_policy` | `map(list(string))`   | *(permissive)* | CSP directives as a map of directive → values. **The default is intentionally permissive and provides essentially no protection — see [Content Security Policy](#content-security-policy) below.** |
| `referrer_policy`         | `string`              | `"same-origin"`| Referrer-Policy header value |
| `geo_restrictions_mode`   | `string`              | `"none"`       | `"none"`, `"whitelist"`, or `"blacklist"` |
| `geo_restrictions_list`   | `list(string)`        | `[]`           | Country codes for geo-restriction |
| `create_robots_txt`       | `bool`                | `true`         | Auto-generate a disallow-all `robots.txt` |
| `lambda_src_dir`          | `string`              | `null`         | Path to Lambda@Edge source directory. If omitted, Lambda@Edge is disabled entirely. |
| `lambda_dist_dir`         | `string`              | `null`         | Custom output path for the Lambda zip. Defaults to `${lambda_src_dir}/../lambda.zip` |

## Architecture

```
                   ┌──────────────┐
                   │   Route 53   │
                   │  DNS Records │
                   └──────┬───────┘
                          │
              ┌───────────┴───────────┐
              │                       │
     ┌────────▼────────┐    ┌────────▼────────┐
     │   CloudFront    │    │   CloudFront    │
     │  (main site)    │    │ (www redirect)  │
     │  + Security     │    └────────┬────────┘
     │    Headers      │             │
     │  + Lambda@Edge  │    ┌────────▼────────┐
     │    (optional)   │    │   S3 Bucket     │
     └────────┬────────┘    │ (www redirect)  │
              │             └─────────────────┘
     ┌────────▼────────┐
     │   S3 Bucket     │
     │  (site files)   │
     └─────────────────┘
```

## Cache Behavior

The module automatically sets `Cache-Control` headers on uploaded S3 objects:

| Pattern | Cache-Control | Example |
|---------|--------------|---------|
| Vite-style hash (`name-HASH.ext`) | `max-age=31536000, immutable` | `index-D4kpuNiu.js` |
| Webpack-style hash (`name.HASH.ext`) | `max-age=31536000, immutable` | `main.a1b2c3d4.js` |
| No hash detected | `no-cache` | `index.html` |

## Content Security Policy

The `content_security_policy` variable is emitted as the `Content-Security-Policy`
response header (via the CloudFront response-headers policy) and takes a map of
directive → list of allowed sources:

```hcl
content_security_policy = {
  default-src = ["'self'"]
  script-src  = ["'self'", "https://cdn.example.com"]
  style-src   = ["'self'", "'unsafe-inline'"]
  img-src     = ["'self'", "data:"]
  connect-src = ["'self'", "https://api.example.com"]
}
```

> ⚠️ **The default value is intentionally permissive and provides essentially
> no security benefit.** It sets `default-src *` with `'unsafe-inline'`,
> `'unsafe-eval'`, and wildcard `frame-ancestors`, which allows scripts, styles,
> and connections from any origin. This maximizes compatibility out of the box
> but effectively disables CSP as a protection. **For any production site you
> should override this variable with a policy scoped to the specific origins
> your app actually uses.**

Note that the module also sets `X-Frame-Options: DENY` unconditionally. Because
`X-Frame-Options` takes precedence over CSP `frame-ancestors` in browsers that
support both, the site cannot be framed regardless of the `frame-ancestors`
value in your CSP.

## Lambda@Edge

When `lambda_src_dir` is provided, the module creates a Lambda@Edge function that runs on `origin-response` events. The source directory should contain a Node.js Lambda function (e.g., `index.js` + `package.json`).

The Lambda is deployed to `us-east-1` (via `aws.acm` provider) as required by CloudFront, and is granted read-only access (`s3:GetObject`, `s3:ListBucket`) scoped to the site bucket only.

When `lambda_src_dir` is omitted, all Lambda resources are skipped entirely.
