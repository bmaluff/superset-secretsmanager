resource "aws_secretsmanager_secret" "superset" {
  name = var.name
}
