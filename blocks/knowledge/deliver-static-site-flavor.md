# Deliver Flavor: static-site

The infrastructure archetype ("flavor") this project deploys with. When a stage
generates infrastructure or site code, it MUST fit this flavor exactly — a
deterministic sensor and the deploy pipeline both assume this contract.

## Canonical repository structure

```
site/                      # the static site content (index.html at minimum)
infra/main.tf              # ALL infrastructure, one file, this flavor's template
environments/production.json   # the environment manifest (written by deploy-verify)
.github/workflows/deploy.yml   # the pipeline (pre-provisioned; NEVER modify it)
.github/workflows/destroy.yml  # audited teardown (pre-provisioned; NEVER modify it)
```

## Security invariants (sensor-checked; violations block the stage)

1. No resource is internet-open except CloudFront. The S3 bucket has ALL
   public access blocked; only CloudFront reads it, via Origin Access Control.
2. Every resource carries the tag `Project = "deliver-teste-sample"` (via
   provider `default_tags`) — the teardown audit counts resources by this tag.
3. Bucket names start with `deliver-` (the deploy role is scoped to that prefix).
4. The backend block stays EMPTY (`backend "s3" {}`) — the pipeline injects
   bucket/key/region at init. Never hardcode backend config.

## Terraform template (infra/main.tf)

Use this template verbatim, adjusting only what the intent genuinely requires:

```hcl
terraform {
  required_version = ">= 1.5"
  required_providers {
    aws    = { source = "hashicorp/aws", version = ">= 5.0" }
    random = { source = "hashicorp/random", version = ">= 3.0" }
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

resource "aws_cloudfront_distribution" "site" {
  enabled             = true
  default_root_object = "index.html"
  price_class         = "PriceClass_100"

  origin {
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_id                = "s3-site"
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
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
```

The three outputs (`site_bucket`, `distribution_id`, `site_url`) are REQUIRED —
the pipeline's publish and smoke-test steps read them by name.

## Environment manifest (environments/production.json)

Written by the deploy-verify stage after a verified deploy. Required keys:

```json
{
  "environment": "production",
  "flavor": "static-site",
  "status": "deployed",
  "url": "https://<cloudfront-domain>",
  "commit": "<sha that reached main>",
  "pipeline_run": "<github actions run url>",
  "deployed_at": "<ISO-8601 UTC>",
  "verified_http_status": 200,
  "resources": {
    "site_bucket": "...",
    "distribution_id": "..."
  }
}
```
