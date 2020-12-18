terraform {
  required_version = "~> 0.12.24"

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
  version = "~> 2.45"
}

provider "aws" {
  alias  = "us-east-1"
  region  = "us-east-1"
  profile = "foghorn-io-brad"
  version = "~> 2.45"
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
  tags         = {
    Name        = var.cluster_name
    Terraform   = "true"
    Environment = "poc"
  }
  eks_map_accounts = list(data.aws_caller_identity.current.account_id)
}

variable "zones" {
  default = ["us-west-2a", "us-west-2b", "us-west-2c"]
}

module "vpc" {
  source = "git@github.com:terraform-aws-modules/terraform-aws-vpc.git"

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

data "aws_eks_cluster" "eks" {
  name = module.eks.cluster_id
}

data "aws_eks_cluster_auth" "eks" {
  name = module.eks.cluster_id
}

provider "kubernetes" {
  alias                  = "eks"
  host                   = data.aws_eks_cluster.eks.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.eks.certificate_authority.0.data)
  token                  = data.aws_eks_cluster_auth.eks.token
  load_config_file       = false
  version                = "1.11.1"
}

module "eks" {
  #source = "git@github.com:terraform-aws-modules/terraform-aws-eks.git?ref=v9.0.0"
  source = "./modules/terraform-aws-eks"

  providers = {
    kubernetes = kubernetes.eks
  }

  manage_aws_auth = true
  cluster_name    = local.cluster_name
  subnets         = module.vpc.private_subnets
  vpc_id          = module.vpc.vpc_id
  cluster_version = "1.15"
  map_roles       = [
    {
      rolearn = aws_iam_role.istio.arn
      username = "${var.cluster_name}"
      groups = ["system:masters"]
    },
    {
      rolearn = "arn:aws:iam::238080251717:role/test-assumed-1"
      username = "test-assumed-1"
      groups = ["system:masters"]
    #},
    #{
    #  rolearn = "arn:aws:iam::238080251717:role/test-assumed-2"
    #  username = "test-assumed-1"
    #  groups = ["system:masters"]
    }
  ]

  workers_additional_policies = [
    aws_iam_policy.route53_admin.arn
  ]

      #ami_id                = "ami-0e4209e662d291738" # 1.15
      #ami_id                = "ami-0bc0d84cc396c4ff9" # 1.16
      #instance_type         = "t3.small"
  worker_groups = [
    {
      instance_type         = "c5.large"
      disk_size             = "5Gi"
      asg_desired_capacity  = 3
      asg_min_size          = 3
      asg_max_size          = 3
      autoscaling_enabled   = false
      protect_from_scale_in = false
    },
  ]

  workers_group_defaults = {
    tags = [
      {
        key                 = "k8s.io/cluster-autoscaler/enabled"
        value               = "true"
        propagate_at_launch = true
      },
      {
        key                 = "k8s.io/cluster-autoscaler/${local.cluster_name}"
        value               = "true"
        propagate_at_launch = true
      }
    ]
  }

  cluster_enabled_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler"
  ]

  map_accounts    = local.eks_map_accounts
  create_eks      = true
  enable_irsa     = true

  tags = merge(local.tags, map("kubernetes.io/cluster/${local.cluster_name}", "shared"))
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
  delegation_set_id = "N03386422VXZJKGR4YO18"
}

resource "aws_route53_zone" "zone" {
  name              = "${var.cluster_name}.aws.bradandmarsha.com"
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
  name    = aws_acm_certificate.cert.domain_validation_options.0.resource_record_name
  type    = aws_acm_certificate.cert.domain_validation_options.0.resource_record_type
  zone_id = aws_route53_zone.zone.zone_id
  records = [aws_acm_certificate.cert.domain_validation_options.0.resource_record_value]
  ttl     = 60
}

resource "aws_acm_certificate_validation" "cert" {
  provider                = aws.us-east-1
  certificate_arn         = aws_acm_certificate.cert.arn
  validation_record_fqdns = [aws_route53_record.cert_validation.fqdn]
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
