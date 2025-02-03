#----------------------------------------------------------------
# 1. セキュリティグループ
#----------------------------------------------------------------
# ECS タスク用 SG (ALB の SG からのみ8080番ポートを許可)
resource "aws_security_group" "ecs_sg" {
  name        = "ecs-app-sg"
  description = "Security Group for ECS tasks"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Allow HTTP from ALB"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  egress {
    description      = "Allow all outbound"
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}

#----------------------------------------------------------------
# 2. ALB (Application Load Balancer)
#----------------------------------------------------------------
# ターゲットグループ (IP タイプで Fargate タスクを登録)
resource "aws_lb_target_group" "fargate_spot" {
  name        = "fargate-spot-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/healthz"
    matcher             = "200"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 30
    timeout             = 5
  }
}

# ホストベースルーティングで サブドメインを fargate タスクへフォワード
resource "aws_lb_listener_rule" "fargate_spot_rule" {
  listener_arn = aws_lb_listener.https_listener.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.fargate_spot.arn
  }

  condition {
    host_header {
      values = ["fargate.${var.hosted_zone_name}"]
    }
  }
}

#----------------------------------------------------------------
# 3. ECS 用 IAM ロール (タスク実行ロール)
#----------------------------------------------------------------
data "aws_iam_policy_document" "ecs_task_execution_role_assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_task_execution_role" {
  name               = "ecsTaskExecutionRole"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_execution_role_assume_role_policy.json
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy_attachment" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

#----------------------------------------------------------------
# 4. ECS クラスター
#----------------------------------------------------------------
resource "aws_ecs_cluster" "this" {
  name = "example-spot-cluster"
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    base              = 0
    weight            = 1
  }
}

#----------------------------------------------------------------
# 5. ECS タスク定義
#----------------------------------------------------------------
resource "aws_cloudwatch_log_group" "fargate_streamlit_logs" {
  name              = "/ecs/fargate-streamlit"
  retention_in_days = 7

  tags = {
    Name = "ecs-streamlit-log-group"
  }
}

resource "aws_ecs_task_definition" "streamlit_fargate" {
  family                   = "streamlit-task"
  cpu                      = 512
  memory                   = 2048
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = jsonencode([
    {
      name      = "streamlit"
      image     = "aminehy/docker-streamlit-app"
      essential = true
      portMappings = [
        {
          containerPort = 8080
          hostPort      = 8080
          protocol      = "tcp"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          # 利用するリージョン (例: ap-northeast-1)
          "awslogs-region" = "ap-northeast-1"
          "awslogs-group"  = aws_cloudwatch_log_group.fargate_streamlit_logs.name
          # コンテナ単位でプレフィックスを付与
          "awslogs-stream-prefix" = "streamlit"
        }
      }
    }
  ])
}

#----------------------------------------------------------------
# 6. ECS サービス (FARGATE_SPOT & ALB に紐づけ / パスルーティング)
#----------------------------------------------------------------
resource "aws_ecs_service" "fargate_service" {
  name            = "fargate-service-spot"
  cluster         = aws_ecs_cluster.this.arn
  task_definition = aws_ecs_task_definition.streamlit_fargate.arn
  desired_count   = 1

  # launch_type は指定しない
  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 1
  }

  # Fargate タスクにパブリック IP を割り当てない (NAT 経由でインターネットに出る想定)
  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.ecs_sg.id]
    assign_public_ip = false
  }

  # ALB のターゲットグループとの関連付け
  load_balancer {
    target_group_arn = aws_lb_target_group.fargate_spot.arn
    container_name   = "streamlit"
    container_port   = 8080
  }

  depends_on = [
    aws_ecs_cluster.this,
    aws_lb_listener_rule.fargate_spot_rule
  ]
}