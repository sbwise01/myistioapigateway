terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 4.47"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.16"
    }
  }

  backend "s3" {
    bucket = "bw-terraform-state-us-east-1"
    key    = "istio.tfstate"
    region = "us-east-1"
    profile = "foghorn-io-brad"
  }
}

data "aws_caller_identity" "current" {}

provider "aws" {
  region  = "us-west-2"
  profile = "foghorn-io-brad"
}

provider "aws" {
  alias  = "us-east-1"
  region  = "us-east-1"
  profile = "foghorn-io-brad"
}

resource "random_string" "suffix" {
  length  = 4
  special = false
}

# Note this is also used to construct sub-zone of aws.bradandmarsha.com
variable "cluster_name" {
  default = "istio"
}

locals {
  cluster_name = "${var.cluster_name}-eks-${random_string.suffix.result}"
  cluster_version = "1.25"
  disk_size       = 40
  instance_type   = "m5.2xlarge"
  tags         = {
    Name        = var.cluster_name
    Terraform   = "true"
    Environment = "poc"
  }
  additional_eks_tags = {
    CommunityModuleVersion = "19.5.1"
    K8sVersion             = local.cluster_version
  }
  tags_nodegroup = {
    "k8s.io/cluster-autoscaler/enabled"               = "true"
    "k8s.io/cluster-autoscaler/${local.cluster_name}" = "owned"
  }
}

variable "zones" {
  default = ["us-west-2a", "us-west-2b", "us-west-2c"]
}

module "vpc" {
  source = "git@github.com:terraform-aws-modules/terraform-aws-vpc.git?ref=v4.0.2"

  name = "${var.cluster_name}"
  cidr = "10.11.0.0/16"
  azs  = var.zones

  private_subnets = ["10.11.0.0/24", "10.11.1.0/24", "10.11.2.0/24"]
  public_subnets  = ["10.11.3.0/24", "10.11.4.0/24", "10.11.5.0/24"]

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                      = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"             = "1"
  }

  enable_nat_gateway = true

  tags = local.tags
}

data "aws_eks_cluster_auth" "eks" {
  name = module.eks.cluster_name
}

provider "kubernetes" {
  alias                  = "eks"
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.eks.token
}

module "eks" {
  source = "git@github.com:terraform-aws-modules/terraform-aws-eks.git?ref=v19.5.1"

  providers = {
    kubernetes = kubernetes.eks
  }

  create          = true
  cluster_name    = local.cluster_name
  cluster_version = local.cluster_version

  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
      configuration_values = jsonencode({
        env = {
          # Reference docs https://docs.aws.amazon.com/eks/latest/userguide/cni-increase-ip-addresses.html
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
    aws-ebs-csi-driver = {
      most_recent = true
    }
  }

  cluster_enabled_log_types              = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  cloudwatch_log_group_retention_in_days = 7

  cluster_security_group_additional_rules = {
    cluster_ingress_public = {
      description = "K8s Cluster API Public Access"
      protocol    = "tcp"
      from_port   = 443
      to_port     = 443
      cidr_blocks = ["0.0.0.0/0"]
      type        = "ingress"
    }
  }

  node_security_group_additional_rules = {
    cluster_ingress_istiod_injector = {
      description                   = "IstioD Injector"
      protocol                      = "tcp"
      from_port                     = 15017
      to_port                       = 15017
      source_cluster_security_group = true
      type                          = "ingress"
    }
  }

  create_kms_key = false
  cluster_encryption_config = {
    resources        = ["secrets"]
    provider_key_arn = aws_kms_key.eks.arn
  }

  tags = merge(local.additional_eks_tags, local.tags)

  # create_aws_auth_configmap = true
  manage_aws_auth_configmap = true

  aws_auth_roles = [
    {
      rolearn = aws_iam_role.istio.arn
      username = "${var.cluster_name}"
      groups = ["system:masters"]
    }
  ]

  eks_managed_node_groups = {
    default_node_group = {
      name = "${local.cluster_name}-managed"

      ############### Launch template ###############
      # AMI comes from: https://github.com/awslabs/amazon-eks-ami
      create_launch_template = true
      launch_template_name   = "${local.cluster_name}-lc"

      ebs_optimized = true

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"

          ebs = {
            volume_size = local.disk_size
            volume_type = "gp3"
            encrypted   = true
          }
        }
      }

      subnet_ids = module.vpc.private_subnets

      min_size     = 1
      max_size     = 6
      desired_size = 3

      instance_types = [local.instance_type]
      capacity_type  = "ON_DEMAND"

      bootstrap_extra_args = "--kubelet-extra-args '--max-pods=110'"

      update_config = {
        max_unavailable_percentage = 75 # or set `max_unavailable`
      }

      create_iam_role              = true
      iam_role_name                = "${local.cluster_name}-eks-managed-node-group"
      iam_role_use_name_prefix     = false
      iam_role_description         = "${local.cluster_name} EKS managed node group role"
      iam_role_additional_policies = {}
      iam_role_tags                = local.tags

      # A list of security group IDs to associate
      vpc_security_group_ids = []

      tags = merge(local.tags, local.tags_nodegroup)
    }
  }
}

# KMS key for secret envelope encryption
resource "aws_kms_key" "eks" {
  description             = "EKS Secret Encryption Key for ${local.cluster_name}"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  tags = merge({
    Name = "${local.cluster_name}-key"
    Note = "Created by terraform for EKS cluster ${local.cluster_name}"
  }, local.tags)
}

# https://docs.aws.amazon.com/eks/latest/userguide/managing-vpc-cni.html
module "vpc_cni_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name_prefix      = "${module.eks.cluster_name}-VPC-CNI-IRSA"
  attach_vpc_cni_policy = true
  vpc_cni_enable_ipv4   = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-node"]
    }
  }
}

# https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html

module "irsa_ebs_csi" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.8.0"

  role_name = "${local.cluster_name}-IRSA-EBS-CSI"
  role_description = "IRSA for EBS CSI"
  attach_ebs_csi_policy = true
  policy_name_prefix = "${local.cluster_name}-IRSA-EBS-CSI"

  oidc_providers = {
    main = {
      provider_arn = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

resource "kubernetes_service_account" "ebs_csi" {
  provider = kubernetes.eks

  metadata {
    name = "ebs-csi-controller-sa"
    namespace = "kube-system"

    annotations = {
      "eks.amazonaws.com/role-arn" = module.irsa_ebs_csi.iam_role_arn
    }

    labels = {
      "app.kubernetes.io/component" = "csi-driver"
      "app.kubernetes.io/managed-by" = "EKS"
      "app.kubernetes.io/name" = "aws-ebs-csi-driver"
      "app.kubernetes.io/version" = "1.13.0"
    }

  }
}

# https://cert-manager.io/docs/configuration/acme/dns01/route53/
data "aws_iam_policy_document" "cert_manager_policy_doc" {
  statement {
    sid = "certManagerGetChange"
    actions = [
      "route53:GetChange"
    ]
    effect    = "Allow"
    resources = ["arn:aws:route53:::change/*"]
  }
  statement {
    sid = "certManagerChange"
    actions = [
      "route53:ChangeResourceRecordSets",
      "route53:ListResourceRecordSets"
    ]
    effect    = "Allow"
    resources = [aws_route53_zone.zone.arn]
  }
  statement {
    sid = "certManagerList"
    actions = [
      "route53:ListHostedZonesByName"
    ]
    effect    = "Allow"
    resources = ["*"]
  }
}

module "irsa_cert_manager_policy" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-policy"
  version = "5.8.0"

  name        = "${local.cluster_name}-IRSA-Cert-Manager"
  description = "IRSA policy for Cluster Autoscaler"
  policy      = data.aws_iam_policy_document.cert_manager_policy_doc.json
  tags        = local.tags
}

module "irsa_cert_manager" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.8.0"

  role_name          = "${local.cluster_name}-IRSA-Cert-Manager"
  role_description   = "IRSA for Certificate Manager"
  policy_name_prefix = "${local.cluster_name}-IRSA-Cert-Manager"
  role_policy_arns = {
    cert_manager = module.irsa_cert_manager_policy.arn
  }

  oidc_providers = {
    main = {
      provider_arn = module.eks.oidc_provider_arn
      namespace_service_accounts = [
        "cert-manager:cert-manager",
        "cert-manager:cert-manager-cainjector",
        "cert-manager:cert-manager-webhook"
      ]
    }
  }
}

resource "kubernetes_service_account" "cert_manager" {
  provider = kubernetes.eks

  metadata {
    name      = "cert-manager"
    namespace = "cert-manager"

    annotations = {
      "eks.amazonaws.com/role-arn" = module.irsa_cert_manager.iam_role_arn
    }

    labels = {
      "app"                          = "cert-manager"
      "app.kubernetes.io/component"  = "controller"
      "app.kubernetes.io/instance"   = "cert-manager"
      "app.kubernetes.io/managed-by" = "EKS"
      "app.kubernetes.io/name"       = "cert-manager"
      "app.kubernetes.io/version"    = "v1.11.0"
    }
  }
}

resource "kubernetes_service_account" "cert_manager_cainjector" {
  provider = kubernetes.eks

  metadata {
    name      = "cert-manager-cainjector"
    namespace = "cert-manager"

    annotations = {
      "eks.amazonaws.com/role-arn" = module.irsa_cert_manager.iam_role_arn
    }

    labels = {
      "app"                          = "cainjector"
      "app.kubernetes.io/component"  = "cainjector"
      "app.kubernetes.io/instance"   = "cert-manager"
      "app.kubernetes.io/managed-by" = "EKS"
      "app.kubernetes.io/name"       = "cainjector"
      "app.kubernetes.io/version"    = "v1.11.0"
    }
  }
}

resource "kubernetes_service_account" "cert_manager_webhook" {
  provider = kubernetes.eks

  metadata {
    name      = "cert-manager-webhook"
    namespace = "cert-manager"

    annotations = {
      "eks.amazonaws.com/role-arn" = module.irsa_cert_manager.iam_role_arn
    }

    labels = {
      "app"                          = "webhook"
      "app.kubernetes.io/component"  = "webhook"
      "app.kubernetes.io/instance"   = "cert-manager"
      "app.kubernetes.io/managed-by" = "EKS"
      "app.kubernetes.io/name"       = "webhook"
      "app.kubernetes.io/version"    = "v1.11.0"
    }
  }
}

resource "aws_iam_policy" "route53_admin" {
  name   = "${var.cluster_name}-eks-route53-admin"
  policy = data.aws_iam_policy_document.route53_admin.json
}

data "aws_iam_policy_document" "route53_admin" {
  statement {
    effect    = "Allow"
    resources = ["*"]
    actions   = ["route53:*"]
  }
}

data "aws_iam_policy" "admin" {
  arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_role" "istio" {
  name               = "${local.cluster_name}_oidc-${var.cluster_name}"
  tags               = local.tags
  assume_role_policy = data.aws_iam_policy_document.trust_policy.json
}

resource "aws_iam_role_policy_attachment" "istio-policy" {
  role       = aws_iam_role.istio.name
  policy_arn = data.aws_iam_policy.admin.arn
}

data "aws_iam_policy_document" "trust_policy" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.oidc_provider_arn, "/arn:aws:iam::[0-9]{12}:oidc-provider\\//", "")}:sub"
      values   = ["system:serviceaccount:default:${var.cluster_name}"]
    }
  }
}

resource "kubernetes_service_account" "service_accounts" {
  provider = kubernetes.eks

  automount_service_account_token = true
  metadata {
    name      = var.cluster_name
    namespace = "default"
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.istio.arn
    }
  }
}

resource "aws_route53_zone" "parent_zone" {
  name              = "aws.bradandmarsha.com"
  delegation_set_id = "N01336602XUIEH4QJIV0F"
}

resource "aws_route53_zone" "zone" {
  name              = "${var.cluster_name}.aws.bradandmarsha.com"
}

resource "kubernetes_config_map" "zone-ids" {
  provider = kubernetes.eks

  metadata {
    name      = "zone-ids"
    namespace = "default"
  }

  data = {
    parent_zone_id = aws_route53_zone.parent_zone.id
    main_zone_id   = aws_route53_zone.zone.id
  }
}

resource "aws_route53_record" "delegation" {
  allow_overwrite = true
  name            = var.cluster_name
  ttl             = 300
  type            = "NS"
  zone_id         = aws_route53_zone.parent_zone.id
  records         = aws_route53_zone.zone.name_servers
}

resource "aws_acm_certificate" "cert" {
  provider          = aws.us-east-1
  domain_name       = "${var.cluster_name}.aws.bradandmarsha.com"
  subject_alternative_names = ["*.${var.cluster_name}.aws.bradandmarsha.com"]
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.cert.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  name            = each.value.name
  type            = each.value.type
  zone_id         = aws_route53_zone.zone.zone_id
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "cert" {
  provider                = aws.us-east-1
  certificate_arn         = aws_acm_certificate.cert.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

output "domain_name" {
  value = "${var.cluster_name}.aws.bradandmarsha.com"
}

output "acm_cert_arn" {
  value = aws_acm_certificate.cert.arn
}

output "zone_id" {
  value = aws_route53_zone.zone.id
}

output "eks_cluster_id" {
  value = module.eks.cluster_id
}

output "eks_cluster_name" {
  value = local.cluster_name
}
