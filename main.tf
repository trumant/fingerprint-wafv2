// a bucket to serve as our origin
module "s3_bucket" {
  source = "terraform-aws-modules/s3-bucket/aws"

  bucket = "fingerprint-allowlist-demo"

  versioning = {
    enabled = true
  }
}

// simple index for our origin
resource "aws_s3_object" "index" {
  bucket = module.s3_bucket.s3_bucket_id
  key    = "index.html"
  source = "index.html"
}

// enable origin access control
resource "aws_s3_bucket_policy" "bucket_policy" {
  bucket = module.s3_bucket.s3_bucket_id

  policy = data.aws_iam_policy_document.s3_policy.json
}

// allow the cloudfront distribution to read from our bucket
// see https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-restricting-access-to-s3.html#oac-permission-to-access-s3
data "aws_iam_policy_document" "s3_policy" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::${module.s3_bucket.s3_bucket_id}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = ["${module.cloudfront.cloudfront_distribution_arn}"]
    }
  }
}

resource "aws_wafv2_rule_group" "fingerprint_allowlist" {
  name     = "fingerprint-allowlist"
  scope    = "CLOUDFRONT"
  capacity = 6

  rule {
    name     = "fingerprint-allow"
    priority = 1

    action {
      allow {}
    }
    statement {
      or_statement {
        statement {
          byte_match_statement {
            field_to_match {
              ja3_fingerprint {
                fallback_behavior = "NO_MATCH"
              }
            }
            positional_constraint = "EXACTLY"
            search_string         = "375c6162a492dfbf2795909110ce8424"
            text_transformation {
              priority = 0
              type     = "NONE"
            }
          }
        }
        statement {
          byte_match_statement {
            field_to_match {
              ja3_fingerprint {
                fallback_behavior = "NO_MATCH"
              }
            }
            positional_constraint = "EXACTLY"
            search_string         = "773906b0efdefa24a7f2b8eb6985bf37"
            text_transformation {
              priority = 0
              type     = "NONE"
            }
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "fingerprint-allow"
      sampled_requests_enabled   = true
    }
  }
  rule {
    name     = "fingerprint-block"
    priority = 2

    action {
      block {}
    }

    statement {
      byte_match_statement {
        field_to_match {
          ja3_fingerprint {
            fallback_behavior = "NO_MATCH"
          }
        }
        positional_constraint = "EXACTLY"
        search_string         = "06c5844b8643740902c45410712542e0"
        text_transformation {
          priority = 0
          type     = "NONE"
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "fingerprint-block"
      sampled_requests_enabled   = true
    }
  }
  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "fingerprint-demo"
    sampled_requests_enabled   = true
  }
}

resource "aws_wafv2_web_acl" "fingerprint_allowlist_webacl" {
  name  = "fingerprint_allowlist"
  scope = "CLOUDFRONT"

  default_action {
    block {}
  }

  rule {
    name     = "ja3-allowlist"
    priority = 1
    override_action {
      none {}
    }
    statement {
      rule_group_reference_statement {
        arn = aws_wafv2_rule_group.fingerprint_allowlist.arn
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = false
      metric_name                = "ja3-allowlist"
      sampled_requests_enabled   = false
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "fingerprint-allowlist"
    sampled_requests_enabled   = true
  }
}

module "cloudfront" {
  source = "terraform-aws-modules/cloudfront/aws"

  comment             = "Fingerprint CloudFront"
  enabled             = true
  is_ipv6_enabled     = true
  price_class         = "PriceClass_All"
  retain_on_delete    = false
  wait_for_deployment = false
  default_root_object = "index.html"
  web_acl_id          = aws_wafv2_web_acl.fingerprint_allowlist_webacl.arn

  create_origin_access_control = true
  origin_access_control = {
    s3_oac = {
      description      = "CloudFront access to S3"
      origin_type      = "s3"
      signing_behavior = "always"
      signing_protocol = "sigv4"
    }
  }

  origin = {
    s3_one = {
      domain_name           = module.s3_bucket.s3_bucket_bucket_regional_domain_name
      origin_access_control = "s3_oac"
    }
  }

  default_cache_behavior = {
    target_origin_id       = "s3_one"
    viewer_protocol_policy = "https-only"

    allowed_methods = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods  = ["GET", "HEAD"]
    compress        = true
    query_string    = true

    cache_policy_name            = "Managed-CachingOptimized"
    use_forwarded_values         = false
    response_headers_policy_name = "Managed-SimpleCORS"
  }
}