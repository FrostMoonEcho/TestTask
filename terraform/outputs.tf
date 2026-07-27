output "vpc_id" {
  description = "Cell VPC ID."
  value       = aws_vpc.main.id
}

output "k3s_instance_id" {
  description = "Private K3s EC2 instance ID used for SSM operations."
  value       = aws_instance.k3s_node.id
}

output "k3s_private_ip" {
  description = "Private IP used by approved management/deploy networks."
  value       = aws_instance.k3s_node.private_ip
}

output "rds_endpoint" {
  description = "RDS PostgreSQL hostname; no credentials are included."
  value       = aws_db_instance.billing.address
}

output "rds_port" {
  description = "RDS PostgreSQL port."
  value       = aws_db_instance.billing.port
}

output "rds_instance_arn" {
  description = "RDS instance ARN."
  value       = aws_db_instance.billing.arn
}

output "billing_exports_bucket_name" {
  description = "Billing exports S3 bucket name."
  value       = aws_s3_bucket.billing_exports.id
}

output "billing_exports_bucket_arn" {
  description = "Billing exports S3 bucket ARN."
  value       = aws_s3_bucket.billing_exports.arn
}

output "billing_ecr_repository_url" {
  description = "ECR repository URL consumed by the build workflow."
  value       = aws_ecr_repository.billing_service.repository_url
}

output "billing_ecr_repository_arn" {
  description = "ECR repository ARN."
  value       = aws_ecr_repository.billing_service.arn
}

output "k3s_node_role_arn" {
  description = "Least-privilege EC2 role used by the private K3s node."
  value       = aws_iam_role.k3s_node.arn
}

output "github_ecr_push_role_arn" {
  description = "OIDC role used by main-branch image builds."
  value       = aws_iam_role.github_ecr_push.arn
}

output "github_deploy_role_arn" {
  description = "OIDC role used only by the protected production environment."
  value       = aws_iam_role.github_deploy.arn
}

output "data_kms_key_arn" {
  description = "Cell data KMS key ARN."
  value       = aws_kms_key.data.arn
}
