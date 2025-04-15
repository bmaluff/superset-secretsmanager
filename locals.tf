locals {
  superset_values = {
    "SUPERSETNODE_ENV_SECRET" = aws_secretsmanager_secret.superset.name
    "SUPERSET_ROLE_ARN" = module.eks_blueprints_addons.external_secrets.iam_role_arn
  }
}