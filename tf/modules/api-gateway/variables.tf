variable "acm_certificate_arn" {
  description = "The ARN for the ACM certificate to associate with the API Gateway domain"
  type        = string
}

variable "api_gateway_security_policy" {
  description = "The TLS security policy to associate with the API Gateway domain"
  type        = string
  default     = "TLS_1_2"
}

variable "application_subdomain" {
  description = "A subdomain name to create associated DNS records for the API Gateway domain and the Origin Load Balancer"
  type        = string
}

variable "load_balancer_arn" {
  description = "The ARN for the AWS Load Balancer to create associated Origin DNS record"
  type        = string
}

variable "origin_subdomain" {
  description = "A subdomain name to create associated DNS record for the Origin Load Balancer, if not provided then application_subdomain will be used to derive"
  type        = string
  default     = null
}

variable "rest_api_name" {
  description = "The name of the REST API"
  type        = string
}

variable "rest_api_description" {
  description = "A description of the REST API"
  type        = string
}

variable "rest_api_body" {
  description = "A fully rendered body of type OpenAPI specification that defines the set of routes and integrations to create as part of the REST API"
  type        = string
}

variable "route53_zone_id" {
  description = "A Route53 zone ID to create the associated DNS records in"
  type        = string
}

variable "stage_name" {
  description = "The name of the stage created for the REST API deployment"
  type        = string
  default     = "api"
}

variable "tag_map" {
  description = "A default tag map to be placed on all possible resources created by this module."
  type        = map(any)
  default     = {}
}
