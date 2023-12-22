data "aws_route53_zone" "zone" {
  zone_id = var.route53_zone_id
}

data "aws_lb" "ingress_lb" {
  arn = var.load_balancer_arn
}
