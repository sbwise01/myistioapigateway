terraform {
  required_version = "~> 0.12.31"

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
    name      = "istio-internal-ingressgateway"
    namespace = "istio-system"
  }
}

data "aws_lb" "internalingress" {
  name = regex("^[^-]+", data.kubernetes_service.ingress_lb.load_balancer_ingress.0.hostname)
}

provider "aws" {
  region  = "us-west-2"
  profile = "foghorn-io-brad"
  version = "~> 2.45"
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
  name = data.terraform_remote_state.main.outputs.eks_cluster_id
}

data "aws_eks_cluster_auth" "eks" {
  name = data.terraform_remote_state.main.outputs.eks_cluster_id
}

provider "kubernetes" {
  alias                  = "eks"
  host                   = data.aws_eks_cluster.eks.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.eks.certificate_authority.0.data)
  token                  = data.aws_eks_cluster_auth.eks.token
  load_config_file       = false
  version                = "1.11.1"
}

resource "aws_route53_record" "origin-blue" {
  name    = "nlborigin-blue"
  type    = "A"
  zone_id = data.terraform_remote_state.main.outputs.zone_id
  alias {
    evaluate_target_health = false
    name                   = data.aws_lb.internalingress.dns_name
    zone_id                = data.aws_lb.internalingress.zone_id
  }
}

resource "aws_route53_record" "origin-green" {
  name    = "nlborigin-green"
  type    = "A"
  zone_id = data.terraform_remote_state.main.outputs.zone_id
  alias {
    evaluate_target_health = false
    name                   = data.aws_lb.internalingress.dns_name
    zone_id                = data.aws_lb.internalingress.zone_id
  }
}

resource "aws_route53_record" "api" {
  name    = "bookinfo"
  type    = "A"
  zone_id = data.terraform_remote_state.main.outputs.zone_id
  alias {
    evaluate_target_health = false
    name                   = aws_api_gateway_domain_name.applicationdomain.cloudfront_domain_name
    zone_id                = aws_api_gateway_domain_name.applicationdomain.cloudfront_zone_id
  }
}

resource "aws_route53_record" "api-test" {
  name    = "bookinfo-test"
  type    = "A"
  zone_id = data.terraform_remote_state.main.outputs.zone_id
  alias {
    evaluate_target_health = false
    name                   = aws_api_gateway_domain_name.applicationtestdomain.cloudfront_domain_name
    zone_id                = aws_api_gateway_domain_name.applicationtestdomain.cloudfront_zone_id
  }
}

resource "aws_api_gateway_domain_name" "applicationdomain" {
  certificate_arn = data.terraform_remote_state.main.outputs.acm_cert_arn
  domain_name     = "bookinfo.${data.terraform_remote_state.main.outputs.domain_name}"
  security_policy = "TLS_1_2"
  tags            = var.tags
}

resource "aws_api_gateway_domain_name" "applicationtestdomain" {
  certificate_arn = data.terraform_remote_state.main.outputs.acm_cert_arn
  domain_name     = "bookinfo-test.${data.terraform_remote_state.main.outputs.domain_name}"
  security_policy = "TLS_1_2"
  tags            = var.tags
}

resource "aws_api_gateway_vpc_link" "internalingress" {
  name        = "internal-ingress-backend-lb"
  description = "The VPC link to the Istio ingress LB."
  target_arns = [data.aws_lb.internalingress.arn]
  tags        = var.tags
}

resource "aws_api_gateway_rest_api" "restapi" {
  api_key_source     = var.api_key_source
  binary_media_types = var.binary_media_types
  body = templatefile("./swagger30.yaml", {
    OriginName         = aws_route53_record.origin-blue.fqdn
    APIBackend         = data.aws_lb.internalingress.dns_name,
    VPCLinkId          = aws_api_gateway_vpc_link.internalingress.id
    WebBucketName      = aws_s3_bucket.web-bucket.id
    Region             = "us-west-2"
    S3RoleArn          = aws_iam_role.api-gw-s3-role.arn
  })
  description              = "API for Bookinfo"
  minimum_compression_size = var.minimum_compression_size
  name                     = "Bookinfo-API-gateway"
  policy                   = var.gateway_policy
  tags                     = var.tags
}

resource "aws_api_gateway_deployment" "deployment-blue" {
  rest_api_id = aws_api_gateway_rest_api.restapi.id
}

resource "aws_api_gateway_stage" "stage-blue" {
  stage_name    = "blue"
  rest_api_id   = aws_api_gateway_rest_api.restapi.id
  deployment_id = aws_api_gateway_deployment.deployment-blue.id

  cache_cluster_enabled = var.cache_cluster_enabled
  cache_cluster_size    = var.cache_cluster_size
}

resource "aws_api_gateway_deployment" "deployment-green" {
  rest_api_id = aws_api_gateway_rest_api.restapi.id
}

resource "aws_api_gateway_stage" "stage-green" {
  stage_name    = "green"
  rest_api_id   = aws_api_gateway_rest_api.restapi.id
  deployment_id = aws_api_gateway_deployment.deployment-green.id

  cache_cluster_enabled = var.cache_cluster_enabled
  cache_cluster_size    = var.cache_cluster_size
}

resource "aws_api_gateway_base_path_mapping" "base_path_mapping" {
  api_id      = aws_api_gateway_rest_api.restapi.id
  stage_name  = aws_api_gateway_stage.stage-blue.stage_name
  domain_name = aws_api_gateway_domain_name.applicationdomain.domain_name
}

resource "aws_api_gateway_base_path_mapping" "base_path_mapping_test" {
  api_id      = aws_api_gateway_rest_api.restapi.id
  stage_name  = aws_api_gateway_stage.stage-green.stage_name
  domain_name = aws_api_gateway_domain_name.applicationtestdomain.domain_name
}

#resource "aws_api_gateway_method_settings" "methodsettings" {
#  rest_api_id = aws_api_gateway_rest_api.restapi.id
#  stage_name  = aws_api_gateway_stage.stage.stage_name
#  method_path = "*/*"
#  settings {
#    metrics_enabled = true
#    logging_level   = "INFO"
#  }
#}

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
