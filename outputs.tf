output "superset_url" {
  value = try(kubernetes_ingress_v1.superset.status[0].load_balancer[0].ingress[0].hostname, null)
  description = "Superset URL"
}

output "configure_kubectl" {
  description = "Configure kubectl: make sure you're logged in with the correct AWS profile and run the following command to update your kubeconfig"
  value       = "aws eks --region ${data.aws_region.current.name} update-kubeconfig --name ${var.name}"
}