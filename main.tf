/*
 * Module: terraform-aws-backend
 *
 * Bootstrap your terraform backend on AWS.
 *
 * This module configures resources for state locking for terraform >= 0.9.0
 * https://github.com/hashicorp/terraform/blob/master/CHANGELOG.md#090-march-15-2017
 *
 * This template creates and/or manages the following resources
 *   - An S3 Bucket for storing terraform state
 *   - An S3 Bucket for storing logs from the state bucket
 *   - A DynamoDB table to be used for state locking and consistency
 *
 * The DynamoDB state locking table is optional: to disable,
 * set the 'dynamodb_lock_table_enabled' variable to false.
 * For more info on how terraform handles boolean variables:
 *   - https://www.terraform.io/docs/configuration/variables.html
 *
 * If using an existing S3 Bucket, perform a terraform import on your bucket
 * into your terraform-aws-backend module instance:
 *
 * $ terraform import module.backend.aws_s3_bucket.tf_backend_bucket <your_s3_bucket_name>
 *
 * where the 'backend' portion is the name you choose:
 *
 * module "backend" {
 *   source = "github.com/samstav/terraform-aws-backend"
 * }
 *
 */

data "aws_caller_identity" "current" {
}

resource "aws_dynamodb_table" "tf_backend_state_lock_table" {
  count            = var.dynamodb_lock_table_enabled ? 1 : 0
  name             = var.dynamodb_lock_table_name
  read_capacity    = var.lock_table_read_capacity
  write_capacity   = var.lock_table_write_capacity
  hash_key         = "LockID"
  stream_enabled   = var.dynamodb_lock_table_stream_enabled
  stream_view_type = var.dynamodb_lock_table_stream_enabled ? var.dynamodb_lock_table_stream_view_type : ""

  attribute {
    name = "LockID"
    type = "S"
  }
  tags = merge(var.tags, {
    Description        = "Terraform state locking table for account ${data.aws_caller_identity.current.account_id}."
    ManagedByTerraform = "true"
    TerraformModule    = "terraform-aws-backend"
    }
  )

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket" "tf_backend_bucket" {
  bucket = var.backend_bucket
  tags = merge(var.tags, {
    Description        = "Terraform S3 Backend bucket which stores the terraform state for account ${data.aws_caller_identity.current.account_id}."
    ManagedByTerraform = "true"
    TerraformModule    = "terraform-aws-backend"
    }
  )
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tf_backend_bucket_versioning" {
  bucket = aws_s3_bucket.tf_backend_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_logging" "tf_backend_bucket_logging" {
  bucket = aws_s3_bucket.tf_backend_bucket.id

  target_bucket = aws_s3_bucket.tf_backend_logs_bucket.id
  target_prefix = "log/"
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tf_backend_bucket_server_side_encryption" {
  bucket = aws_s3_bucket.tf_backend_bucket.id
  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = var.kms_key_id
      sse_algorithm     = var.kms_key_id == "" ? "AES256" : "aws:kms"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tf_backend_bucket_block_public_access" {
  bucket = aws_s3_bucket.tf_backend_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_acl" "tf_backend_bucket_acl" {
  bucket = aws_s3_bucket.tf_backend_bucket.id
  acl    = "private"
}
data "aws_iam_policy_document" "tf_backend_bucket_policy" {
  statement {
    sid    = "RequireEncryptedTransport"
    effect = "Deny"
    actions = [
      "s3:*",
    ]
    resources = [
      "${aws_s3_bucket.tf_backend_bucket.arn}/*",
    ]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values = [
        false,
      ]
    }
    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }

  # This section is causing the state to fail t be saved to S3 
  # Is it a confusion between AES256 and SSE? 
  # statement {
  #   sid    = "RequireEncryptedStorage"
  #   effect = "Deny"
  #   actions = [
  #     "s3:PutObject",
  #   ]
  #   resources = [
  #     "${aws_s3_bucket.tf_backend_bucket.arn}/*",
  #   ]
  #   condition {
  #     test     = "StringNotEquals"
  #     variable = "s3:x-amz-server-side-encryption"
  #     values = [
  #       var.kms_key_id == "" ? "AES256" : "aws:kms",
  #     ]
  #   }
  #   principals {
  #     type        = "*"
  #     identifiers = ["*"]
  #   }
  # }
}

resource "aws_s3_bucket_policy" "tf_backend_bucket_policy" {
  bucket = aws_s3_bucket.tf_backend_bucket.id
  policy = data.aws_iam_policy_document.tf_backend_bucket_policy.json
}

resource "aws_s3_bucket" "tf_backend_logs_bucket" {
  bucket = "${var.backend_bucket}-logs"
  tags = merge(var.tags, {
    Purpose            = "Logging bucket for ${var.backend_bucket}"
    ManagedByTerraform = "true"
    TerraformModule    = "terraform-aws-backend"
    }
  )
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tf_backend_logs_bucket_versioning" {
  bucket = aws_s3_bucket.tf_backend_logs_bucket.id
  # Logs bucket does not need versioning
  versioning_configuration {
    status = "Disabled"
  }
}

resource "aws_s3_bucket_acl" "tf_backend_logs_bucket_acl" {
  bucket = aws_s3_bucket.tf_backend_logs_bucket.id
  acl    = "log-delivery-write"
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tf_backend_logs_bucket_server_side_encryption" {
  bucket = aws_s3_bucket.tf_backend_logs_bucket.id
  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = var.kms_key_id
      sse_algorithm     = var.kms_key_id == "" ? "AES256" : "aws:kms"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tf_backend_logs_bucket_block_public_access" {
  bucket = aws_s3_bucket.tf_backend_logs_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
