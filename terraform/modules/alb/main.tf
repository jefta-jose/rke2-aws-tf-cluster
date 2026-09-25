# Trimmed from rok-scaleout alb.tf: one public ALB whose HTTP listener forwards to the
# Traefik NodePort target group. Targets (VM IP:NodePort) are registered in Phase 5, not here.
# Lab simplification: plain HTTP :80 forward (no ACM/HTTPS redirect the real stack uses).
resource "aws_security_group" "alb" {
  name   = "${var.name}-sg-alb"
  vpc_id = var.vpc_id

  ingress {
    description = "HTTP from anywhere"
    protocol    = "tcp"
    from_port   = 80
    to_port     = 80
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name}-sg-alb" })
}

resource "aws_lb" "this" {
  name                       = "${var.name}-alb"
  internal                   = false
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.alb.id]
  subnets                    = var.subnet_ids
  enable_deletion_protection = false

  tags = merge(var.tags, { Name = "${var.name}-alb" })
}

resource "aws_lb_target_group" "traefik" {
  name        = "${var.name}-traefik-tg"
  port        = var.traefik_nodeport
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip" # register the VM IP:NodePort directly in Phase 5

  health_check {
    protocol = "HTTP"
    path     = var.health_check_path
    port     = tostring(var.traefik_nodeport)
  }

  tags = merge(var.tags, { Name = "${var.name}-traefik-tg" })
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.traefik.arn
  }
}
