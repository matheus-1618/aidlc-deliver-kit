# Deliver Flavor: lambda-backend

Static frontend + our own serverless backend, behind ONE CloudFront
distribution: `/` serves the site from S3; `/api/*` routes to a Lambda function
URL. No public IPs, no servers, cost ~cents (Lambda bills per request).

Use this flavor when the intent needs a real backend of ours (aggregation,
caching, secrets kept server-side) rather than the browser calling third-party
APIs directly.

## Canonical repository structure

```
site/                      # static frontend (plain HTML+CSS+JS, no build step)
backend/index.mjs          # the Lambda handler (Node.js 22, ESM, handler `handler`)
infra/main.tf              # ALL infrastructure, one file, this flavor's template
environments/production.json   # environment manifest (written by deploy-verify)
.github/workflows/deploy.yml   # pipeline (pre-provisioned; NEVER modify)
.github/workflows/destroy.yml  # audited teardown (pre-provisioned; NEVER modify)
```

The frontend calls the backend at the RELATIVE path `/api/...` — same origin,
no CORS, no hardcoded URLs.

## Security invariants (sensor-checked; violations block the stage)

1. Only CloudFront faces the internet. S3 fully blocked + OAC. The Lambda
   function URL is reached through CloudFront; its own hostname is unadvertised.
2. Every resource tagged `Project = "deliver-teste-sample"` via `default_tags`
   (the Lambda execution role carries the tag too).
3. Names prefixed `deliver-` (bucket, function, role) — the deploy role is
   scoped to that prefix.
4. `backend "s3" {}` stays EMPTY — the pipeline injects config at init.
5. The Lambda execution role has ONLY `AWSLambdaBasicExecutionRole` (logs).
   It creates nothing, reads no secrets, touches no other service.

## Terraform template (infra/main.tf)

```hcl
terraform {
  required_version = ">= 1.5"
  required_providers {
    aws     = { source = "hashicorp/aws", version = ">= 5.0" }
    random  = { source = "hashicorp/random", version = ">= 3.0" }
    archive = { source = "hashicorp/archive", version = ">= 2.0" }
  }
  backend "s3" {}
}

provider "aws" {
  region = "us-west-2"
  default_tags {
    tags = { Project = "deliver-teste-sample", ManagedBy = "aidlc-deliver" }
  }
}

resource "random_id" "suffix" { byte_length = 4 }

# ── Frontend: S3 privado, lido só pelo CloudFront ─────────────────────────────
resource "aws_s3_bucket" "site" {
  bucket        = "deliver-site-${random_id.suffix.hex}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "site" {
  bucket                  = aws_s3_bucket.site.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_cloudfront_origin_access_control" "site" {
  name                              = "deliver-site-${random_id.suffix.hex}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# ── Backend: Lambda + function URL ────────────────────────────────────────────
data "archive_file" "backend" {
  type        = "zip"
  source_dir  = "${path.module}/../backend"
  output_path = "${path.module}/backend.zip"
}

resource "aws_iam_role" "backend" {
  name = "deliver-backend-${random_id.suffix.hex}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "backend_logs" {
  role       = aws_iam_role.backend.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_lambda_function" "backend" {
  function_name    = "deliver-backend-${random_id.suffix.hex}"
  role             = aws_iam_role.backend.arn
  runtime          = "nodejs22.x"
  handler          = "index.handler"
  filename         = data.archive_file.backend.output_path
  source_code_hash = data.archive_file.backend.output_base64sha256
  timeout          = 10
  memory_size      = 128
}

resource "aws_lambda_function_url" "backend" {
  function_name      = aws_lambda_function.backend.function_name
  authorization_type = "NONE"
}

# ── Uma distribuição, duas origens ───────────────────────────────────────────
locals {
  lambda_origin_domain = replace(replace(aws_lambda_function_url.backend.function_url, "https://", ""), "/", "")
}

resource "aws_cloudfront_distribution" "site" {
  enabled             = true
  default_root_object = "index.html"
  price_class         = "PriceClass_100"

  origin {
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_id                = "s3-site"
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  origin {
    domain_name = local.lambda_origin_domain
    origin_id   = "lambda-api"
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "s3-site"
    viewer_protocol_policy = "redirect-to-https"
    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }
  }

  ordered_cache_behavior {
    path_pattern           = "/api/*"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "lambda-api"
    viewer_protocol_policy = "https-only"
    min_ttl                = 0
    default_ttl            = 0
    max_ttl                = 30
    forwarded_values {
      query_string = true
      cookies { forward = "none" }
    }
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate { cloudfront_default_certificate = true }
}

resource "aws_s3_bucket_policy" "site" {
  bucket = aws_s3_bucket.site.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "CloudFrontRead"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.site.arn}/*"
      Condition = {
        StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.site.arn }
      }
    }]
  })
}

output "site_bucket" { value = aws_s3_bucket.site.bucket }
output "distribution_id" { value = aws_cloudfront_distribution.site.id }
output "site_url" { value = "https://${aws_cloudfront_distribution.site.domain_name}" }
output "api_url" { value = "https://${aws_cloudfront_distribution.site.domain_name}/api" }
output "backend_function" { value = aws_lambda_function.backend.function_name }
```

The pipeline's outputs contract still reads `site_bucket`, `distribution_id`
and `site_url` — do not rename them. `api_url` and `backend_function` are
additional and MUST appear in the environment manifest under `resources`.

## Lambda handler contract (backend/index.mjs)

- Node.js 22 ESM, export `handler` (function URL event shape: `event.rawPath`
  starts with `/api/...` as forwarded by CloudFront).
- Respond JSON with explicit `statusCode`, `headers: {"content-type":
  "application/json"}` and stringified `body`.
- Outbound HTTPS calls (e.g. aggregating a public status API) use global
  `fetch`. Cache in a module-level variable with a short TTL to be polite.
- Never expose upstream errors raw: on failure return `{"status":"unknown"}`
  with statusCode 200 and a `stale: true` flag so the frontend renders honesty,
  not a broken page.

## Environment manifest additions

`resources` gains `backend_function` and `api_url` beside `site_bucket` and
`distribution_id`.
