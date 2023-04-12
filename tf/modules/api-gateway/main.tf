resource "aws_api_gateway_rest_api" "this" {
  name                     = var.rest_api_name
  description              = var.rest_api_description
  minimum_compression_size = -1
  body                     = var.rest_api_body
  tags                     = var.tag_map
}

resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  triggers = {
    redeployment = sha1(jsonencode(aws_api_gateway_rest_api.this.body))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "this" {
  stage_name    = var.stage_name
  rest_api_id   = aws_api_gateway_rest_api.this.id
  deployment_id = aws_api_gateway_deployment.this.id
}

resource "aws_api_gateway_domain_name" "this" {
  certificate_arn = var.acm_certificate_arn
  domain_name     = "${var.application_subdomain}.${data.aws_route53_zone.zone.name}"
  security_policy = var.api_gateway_security_policy
  tags            = var.tag_map
}

resource "aws_api_gateway_base_path_mapping" "this" {
  api_id      = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.this.stage_name
  domain_name = aws_api_gateway_domain_name.this.domain_name
}

resource "aws_route53_record" "load_balancer_domain" {
  name    = var.origin_subdomain != null ? var.origin_subdomain : "${var.application_subdomain}-lborigin"
  type    = "A"
  zone_id = data.aws_route53_zone.zone.zone_id
  alias {
    evaluate_target_health = false
    name                   = data.aws_lb.ingress_lb.dns_name
    zone_id                = data.aws_lb.ingress_lb.zone_id
  }
}

resource "aws_route53_record" "this" {
  name    = var.application_subdomain
  type    = "A"
  zone_id = data.aws_route53_zone.zone.zone_id
  alias {
    evaluate_target_health = false
    name                   = aws_api_gateway_domain_name.this.cloudfront_domain_name
    zone_id                = aws_api_gateway_domain_name.this.cloudfront_zone_id
  }
}
