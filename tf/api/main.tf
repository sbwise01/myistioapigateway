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
    key    = "apigateway.tfstate"
    region = "us-east-1"
    profile = "foghorn-io-brad"
  }
}

locals {
  buckets_prefix     = "brad"
}

data "terraform_remote_state" "main" {
  backend = "s3"
  config = {
    bucket = "bw-terraform-state-us-east-1"
    key    = "istio.tfstate"
    region = "us-east-1"
    profile = "foghorn-io-brad"
  }
}

data "aws_caller_identity" "current" {}

data "kubernetes_service" "ingress_lb" {
  provider = kubernetes.eks

  metadata {
    name      = "istio-ingressgateway"
    namespace = "istio-system"
  }
}

data "aws_lb" "internalingress" {
  name = regex("^[^-]+", data.kubernetes_service.ingress_lb.status[0].load_balancer[0].ingress[0].hostname)
}

provider "aws" {
  region  = "us-west-2"
  profile = "foghorn-io-brad"
}

# Mandatory:

variable "tags" {
  type = map(string)
  default = {
    CostCenter = "brad@foghornconsulting.com"
  }
}

# Can be overriden:

# REST API
variable "api_key_source" {
  type        = string
  default     = "HEADER"
  description = "The source of the API key for requests. Valid values are HEADER (default) and AUTHORIZER."
}

variable "binary_media_types" {
  type        = list
  default     = ["UTF-8-encoded", "image/*"]
  description = "The list of binary media types supported by the RestApi. By default, the RestApi supports only UTF-8-encoded text payloads."
}

variable "minimum_compression_size" {
  type        = number
  default     = -1
  description = "Minimum response size to compress for the REST API. Integer between -1 and 10485760 (10MB). Setting a value greater than -1 will enable compression, -1 disables compression (default)."
}

variable "gateway_policy" {
  type    = string
  default = ""
}

variable "cache_cluster_enabled" {
  type        = bool
  default     = false
  description = "Specifies whether a cache cluster is enabled for the stage"
}

variable "cache_cluster_size" {
  type        = string
  default     = "0.5"
  description = "The size of the cache cluster for the stage, if enabled"
}

data "aws_eks_cluster" "eks" {
  name = data.terraform_remote_state.main.outputs.eks_cluster_name
}

data "aws_eks_cluster_auth" "eks" {
  name = data.terraform_remote_state.main.outputs.eks_cluster_name
}

provider "kubernetes" {
  alias                  = "eks"
  host                   = data.aws_eks_cluster.eks.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.eks.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.eks.token
}

resource "aws_s3_bucket" "web-bucket" {
  bucket        = "${local.buckets_prefix}-web-bucket"
  acl           = "private"
  force_destroy = true
  website {
    error_document = "error.html"
    index_document = "index.html"
  }
}

resource "aws_s3_bucket_object" "default-index-page" {
  bucket        = aws_s3_bucket.web-bucket.id
  acl           = "private"
  force_destroy = true
  key           = "index.html"
  content       = templatefile("files/web/index.html", {})
  content_type  = "text/html"
}

resource "aws_s3_bucket_object" "default-image" {
  bucket        = aws_s3_bucket.web-bucket.id
  acl           = "private"
  force_destroy = true
  key           = "images/image.jpg"
  source        = "files/web/images/image.jpg"
  content_type  = "image/jpeg"

  etag = filemd5("files/web/images/image.jpg")
}

data "aws_iam_policy_document" "trust_policy" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["apigateway.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "api-gw-s3-role" {
  name               = "${local.buckets_prefix}-web-bucket-role"
  assume_role_policy = data.aws_iam_policy_document.trust_policy.json
}

resource "aws_iam_role_policy_attachment" "api-gw-s3-policy" {
  role       = aws_iam_role.api-gw-s3-role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
}

resource "aws_api_gateway_vpc_link" "internalingress" {
  name        = "internal-ingress-backend-lb"
  description = "The VPC link to the Istio ingress LB."
  target_arns = [data.aws_lb.internalingress.arn]
  tags        = var.tags
}

module "api_gateway_bookinfo" {
  source = "../modules/api-gateway"

  acm_certificate_arn   = data.terraform_remote_state.main.outputs.acm_cert_arn
  application_subdomain = "bookinfo"
  load_balancer_arn     = data.aws_lb.internalingress.arn
  origin_subdomain      = "nlborigin-blue"
  rest_api_name         = "Bookinfo-API-gateway"
  rest_api_description  = "API for Bookinfo"
  rest_api_body         = templatefile("./swagger30.yaml", {
    OriginName         = "nlborigin-blue.${data.terraform_remote_state.main.outputs.domain_name}"
    VPCLinkId          = aws_api_gateway_vpc_link.internalingress.id
    WebBucketName      = aws_s3_bucket.web-bucket.id
    Region             = "us-west-2"
    S3RoleArn          = aws_iam_role.api-gw-s3-role.arn
  })
  route53_zone_id       = data.terraform_remote_state.main.outputs.zone_id
  stage_name            = "blue"
  tag_map               = var.tags
}

module "api_gateway_bookinfo_test" {
  source = "../modules/api-gateway"

  acm_certificate_arn   = data.terraform_remote_state.main.outputs.acm_cert_arn
  application_subdomain = "bookinfo-test"
  load_balancer_arn     = data.aws_lb.internalingress.arn
  origin_subdomain      = "nlborigin-green"
  rest_api_name         = "Bookinfo-Test-API-gateway"
  rest_api_description  = "API for Bookinfo Test"
  rest_api_body         = templatefile("./swagger30.yaml", {
    OriginName         = "nlborigin-green.${data.terraform_remote_state.main.outputs.domain_name}"
    VPCLinkId          = aws_api_gateway_vpc_link.internalingress.id
    WebBucketName      = aws_s3_bucket.web-bucket.id
    Region             = "us-west-2"
    S3RoleArn          = aws_iam_role.api-gw-s3-role.arn
  })
  route53_zone_id       = data.terraform_remote_state.main.outputs.zone_id
  stage_name            = "green"
  tag_map               = var.tags
}
