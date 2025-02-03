# ─────────────────────────────────────────────────────────────
# ALB用Security Group 
# ─────────────────────────────────────────────────────────────
resource "aws_security_group" "alb_sg" {
  name   = "alb-sg"
  vpc_id = var.vpc_id

  # インターネットの HTTP, HTTPSを許可
  ingress {
    description      = "Allow HTTP"
    from_port        = 80
    to_port          = 80
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  ingress {
    description      = "Allow HTTPS"
    from_port        = 443
    to_port          = 443
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  # アウトバンドを全許可
  egress {
    from_port        = 0
    to_port          = 0
    protocol         = -1
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}


# ─────────────────────────────────────────────────────────────
# ALB の作成
# Public Subnet に配置し、上記 EC2 を Targets として登録
# ─────────────────────────────────────────────────────────────
resource "aws_lb" "alb" {
  name               = "alb"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = var.public_subnet_ids

  # 必要に応じてアクセスログの設定など適宜追加
  tags = {
    Name = "alb"
  }
}

# HTTP リスナー (ポート80)
# すべてのリクエストをHTTPSにリダイレクトする
resource "aws_lb_listener" "http_listener" {
  load_balancer_arn = aws_lb.alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# HTTPS リスナー (ポート443)
# 証明書ARNとポリシーを指定し、ターゲットグループへ転送する
resource "aws_lb_listener" "https_listener" {
  load_balancer_arn = aws_lb.alb.arn
  port              = "443"
  protocol          = "HTTPS"
  certificate_arn   = var.acm_certificate_arn
  ssl_policy        = "ELBSecurityPolicy-2016-08"

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Hello ALB"
      status_code  = "200"
    }
  }
}
