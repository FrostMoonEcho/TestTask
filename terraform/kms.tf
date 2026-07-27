# A cell-scoped customer-managed key protects RDS, S3, ECR, and the node disk.
resource "aws_kms_key" "data" {
  description             = "Data encryption key for ${var.environment}"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  tags = {
    Name = "${var.environment}-data"
  }
}

resource "aws_kms_alias" "data" {
  name          = "alias/${var.environment}-data"
  target_key_id = aws_kms_key.data.key_id
}
