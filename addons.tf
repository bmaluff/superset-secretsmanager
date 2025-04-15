#---------------------------------------------------------------
# GP3 Encrypted Storage Class
#---------------------------------------------------------------
resource "kubernetes_annotations" "disable_gp2" {
  annotations = {
    "storageclass.kubernetes.io/is-default-class" : "false"
  }
  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"
  metadata {
    name = "gp2"
  }
  force = true

  depends_on = [module.eks.eks_cluster_id]
}

resource "kubernetes_storage_class" "default_gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" : "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  allow_volume_expansion = true
  volume_binding_mode    = "WaitForFirstConsumer"
  parameters = {
    fsType    = "ext4"
    encrypted = true
    type      = "gp3"
  }

  depends_on = [kubernetes_annotations.disable_gp2]
}

#---------------------------------------------------------------
# IRSA for EBS CSI Driver
#---------------------------------------------------------------
module "ebs_csi_driver_irsa" {
  source                = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version               = "~> 5.20"
  role_name_prefix      = format("%s-%s", var.name, "ebs-csi-driver-")
  attach_ebs_csi_policy = true
  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
  tags = local.tags
}

module "eks_blueprints_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.2"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  #---------------------------------------
  # Amazon EKS Managed Add-ons
  #---------------------------------------
  eks_addons = {
    aws-ebs-csi-driver = {
      service_account_role_arn = module.ebs_csi_driver_irsa.iam_role_arn
    }
    coredns = {
      preserve = true
    }
    vpc-cni = {
      preserve = true
    }
    kube-proxy = {
      preserve = true
    }
  }

  enable_external_secrets = true
  external_secrets_secrets_manager_arns = [aws_secretsmanager_secret.superset.arn]
  external_secrets = {
    name = var.name
    namespace = "superset"
    service_account_name = "superset-sa" 
    chart_version = "0.15.1"
    set = [
      {
        name = "installCRDs"
        value = "true"
      }
    ]
  }

  #---------------------------------------
  # AWS Load Balancer Controller Add-on
  #---------------------------------------
  enable_aws_load_balancer_controller = true
  # turn off the mutating webhook for services because we are using
  # service.beta.kubernetes.io/aws-load-balancer-type: external
  aws_load_balancer_controller = {
    set = [{
      name  = "enableServiceMutatorWebhook"
      value = "false"
    }]
  }

  tags = local.tags
  depends_on = [ module.eks ]
}

module "eks_data_addons" {
  source  = "aws-ia/eks-data-addons/aws"
  version = "~> 1.31.5" # ensure to update this to the latest/desired version

  oidc_provider_arn = module.eks.oidc_provider_arn

  #---------------------------------------
  # AWS Apache Superset Add-on
  #---------------------------------------
  enable_superset = true
  superset_helm_config = {
    values = [templatefile("${path.module}/helm-values/superset-values.yaml", local.superset_values)]
    version = "0.14.2"
  }
  depends_on = [
    kubectl_manifest.superset_external_secret
  ]
}

#------------------------------------------------------------
# Create AWS Application Load balancer with Ingres
#------------------------------------------------------------
resource "kubernetes_ingress_class_v1" "aws_alb" {
  metadata {
    name = "aws-alb"
  }

  spec {
    controller = "ingress.k8s.aws/alb"
  }

  depends_on = [module.eks]
}

locals {
  alb_ingress_name = "superset-ingress"
}

resource "kubernetes_ingress_v1" "superset" {
  metadata {
    name      = local.alb_ingress_name
    namespace = "superset"
    annotations = {
      "alb.ingress.kubernetes.io/scheme"      = "internet-facing"
      "alb.ingress.kubernetes.io/target-type" = "ip"
    }
  }
  spec {
    ingress_class_name = "aws-alb"
    rule {
      http {
        path {
          path = "/*"
          backend {
            service {
              name = "superset"
              port {
                number = 8088
              }
            }
          }
        }
      }
    }
  }
  wait_for_load_balancer = true

  depends_on = [module.eks_data_addons]
}

resource "random_password" "secret_key" {
  length      = 42
  special     = true
  lower       = true
  upper       = true
  numeric     = true
  min_lower   = 4
  min_numeric = 4
  min_special = 4
  min_upper   = 4
  override_special = "_-#@."
}

resource "kubectl_manifest" "aws_secretsmanager_store" {
  force_new = true
  yaml_body = yamlencode(
    {
      "apiVersion" = "external-secrets.io/v1beta1"
      "kind"       = "SecretStore"
      "metadata" = {
        "name"      = "aws-secretsmanager-store"
        "namespace" = "superset"
      }
      "spec" = {
        "provider" = {
          "aws" = {
            "service" = "SecretsManager"
            "region"  = data.aws_region.current.name
            "auth" = {
              "jwt" = {
                "serviceAccountRef" = {
                  "name" = "superset-sa"
                }
              }
            }
          }
        }
      }
    }
  )
  depends_on = [
    module.eks_blueprints_addons
  ]
}

resource "kubectl_manifest" "superset_external_secret" {
  force_new = true
  yaml_body = yamlencode(
    {
      "apiVersion" = "external-secrets.io/v1beta1"
      "kind"       = "ExternalSecret"
      "metadata" = {
        "name"      = aws_secretsmanager_secret.superset.name
        "namespace" = "superset"
      }
      "spec" = {
        "refreshInterval" = "15s"
        "secretStoreRef" = {
          "name" = kubectl_manifest.aws_secretsmanager_store.name
          "kind" = kubectl_manifest.aws_secretsmanager_store.kind
        }
        "target" = {
          "name"           = aws_secretsmanager_secret.superset.name
          "creationPolicy" = "Owner"
        }
        "dataFrom" = [
          {
            "extract" = {
              "key"      = aws_secretsmanager_secret.superset.name
            }
          }
        ]
      }
    }
  )
  depends_on = [
    kubectl_manifest.aws_secretsmanager_store
  ]
}
