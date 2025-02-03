# ────────────────────────────────────────────────────────────
# 1. IAM ロール (EC2 コンテナインスタンス用)
# ────────────────────────────────────────────────────────────
# ECS コンテナインスタンスが必要とする IAM ロール
resource "aws_iam_role" "ecs_container_instance_role" {
  name               = "ecsContainerInstanceRole"
  assume_role_policy = data.aws_iam_policy_document.ecs_container_instance_assume_role_policy.json
}

data "aws_iam_policy_document" "ecs_container_instance_assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# ECS コンテナインスタンスが最低限必要となるポリシーのアタッチ
resource "aws_iam_role_policy_attachment" "ecs_container_instance_role_attachment" {
  role       = aws_iam_role.ecs_container_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_role_policy_attachment" "ec2_ssm_attach" {
  role       = aws_iam_role.ecs_container_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# EC2 インスタンスにこのロールを割り当てるためのインスタンスプロファイル
resource "aws_iam_instance_profile" "ecs_container_instance_profile" {
  name = "ecsContainerInstanceProfile"
  role = aws_iam_role.ecs_container_instance_role.name
}

# ────────────────────────────────────────────────────────────
# 2. Launch Template (Spot インスタンス用)
# ────────────────────────────────────────────────────────────
# Amazon Linux 2023は動かない
# ECS Optimized AMIのデータソース
# data "aws_ami" "ecs_optimized" {
#   most_recent = true

#   filter {
#     name   = "name"
#     values = ["al2023-ami-ecs-hvm-*-x86_64"]
#   }

#   filter {
#     name   = "virtualization-type"
#     values = ["hvm"]
#   }

#   owners = ["amazon"]
# }

data "aws_ami" "ecs_optimized" {
  most_recent = true

  filter {
    name   = "name"
    values = ["amzn2-ami-ecs-hvm-*-x86_64-ebs"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["amazon"]
}

resource "aws_launch_template" "ecs_spot_lt" {
  name_prefix            = "ecs-spot-lt-"
  image_id               = data.aws_ami.ecs_optimized.id # Amazon Linux 2023 等に変更
  instance_type          = "t3.small"                    # 好みのインスタンスタイプに変更
  vpc_security_group_ids = [aws_security_group.ecs_sg.id]

  # User dataで ECS クラスター名を書き込む
  user_data = base64encode(
    templatefile("${path.module}/user_data.sh", {
      cluster_name = aws_ecs_cluster.this_ec2.name
    })
  )

  iam_instance_profile {
    name = aws_iam_instance_profile.ecs_container_instance_profile.name
  }
}

# ────────────────────────────────────────────────────────────
# 3. Auto Scaling Group (Spot 専用)
# ────────────────────────────────────────────────────────────
resource "aws_autoscaling_group" "ecs_spot_asg" {
  name                  = "ecs-spot-asg"
  max_size              = 2 # ドレインの関係
  min_size              = 0
  desired_capacity      = 1
  vpc_zone_identifier   = var.private_subnet_ids
  protect_from_scale_in = true # スケールイン保護を有効化しておく
  force_delete          = true # terraform destroyがやりやすいようにする

  # 新しいインスタンス起動後、300秒間待機する設定
  default_instance_warmup = 300

  # 全て Spot にする例 (on_demand_base_capacity=0, on_demand_percentage_above_base_capacity=0)
  mixed_instances_policy {
    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.ecs_spot_lt.id
        version            = "$Latest"
      }

      # インスタンスタイプを複数指定するなども可能
      override {
        instance_type = "t3.small"
      }
    }

    instances_distribution {
      on_demand_base_capacity                  = 0
      on_demand_percentage_above_base_capacity = 0
      spot_allocation_strategy                 = "lowest-price"
    }

  }

  # EC2 インスタンスに伝播させるタグを定義
  tag {
    key                 = "Name"
    value               = "my-spot-ecs-instance"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ────────────────────────────────────────────────────────────
# 4. ECS Capacity Provider (Spot 用)
# ────────────────────────────────────────────────────────────
resource "aws_ecs_capacity_provider" "ec2_spot_capacity_provider" {
  name = "ec2-spot-provider"

  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.ecs_spot_asg.arn
    managed_termination_protection = "ENABLED" # Spot からの終了通知時にタスクを Drain する
    managed_scaling {
      status                    = "ENABLED"
      target_capacity           = 100
      minimum_scaling_step_size = 1
      maximum_scaling_step_size = 2
    }
  }
}

# ────────────────────────────────────────────────────────────
# 5. ECS クラスター
# ────────────────────────────────────────────────────────────
resource "aws_ecs_cluster" "this_ec2" {
  name = "example-spotec2-cluster"
}

# クラスターに先ほどの EC2 Spot Capacity Provider を登録しておく (デフォルト戦略にしてもOK)
resource "aws_ecs_cluster_capacity_providers" "this_ec2" {
  cluster_name       = aws_ecs_cluster.this_ec2.name
  capacity_providers = [aws_ecs_capacity_provider.ec2_spot_capacity_provider.name]

  default_capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.ec2_spot_capacity_provider.name
    base              = 0
    weight            = 1
  }
}

# ────────────────────────────────────────────────────────────
# 6. EC2 用 ECS タスク定義
# ────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "ecs_streamlit_logs" {
  name              = "/ecs/ecs-streamlit"
  retention_in_days = 7

  tags = {
    Name = "ecs-streamlit-log-group"
  }
}

resource "aws_ecs_task_definition" "streamlit_ec2" {
  family                   = "streamlit-task-ec2"
  requires_compatibilities = ["EC2"]  # Fargate ではなく EC2
  network_mode             = "awsvpc" # ALB に ip モードで登録したい場合は awsvpc
  cpu                      = 384
  memory                   = 1024
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn # 既存のタスク実行ロールを再利用
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
          "awslogs-region"        = "ap-northeast-1"
          "awslogs-group"         = aws_cloudwatch_log_group.ecs_streamlit_logs.name
          "awslogs-stream-prefix" = "streamlit"
        }
      }
    }
  ])
}

#----------------------------------------------------------------
# 7. ALB (Application Load Balancer)
#----------------------------------------------------------------
# ターゲットグループ (IP タイプで EC2 タスクを登録)
resource "aws_lb_target_group" "ec2_spot" {
  name        = "ec2-spot-tg"
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

# ホストベースルーティングで サブドメインを ec2 タスクへフォワード
resource "aws_lb_listener_rule" "ec2_spot_rule" {
  listener_arn = aws_lb_listener.https_listener.arn
  priority     = 11

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ec2_spot.arn
  }

  condition {
    host_header {
      values = ["ec2.${var.hosted_zone_name}"]
    }
  }
}

# ────────────────────────────────────────────────────────────
# 8. ECS サービス (EC2 Spot で起動 / ALB に紐づけ)
# ────────────────────────────────────────────────────────────
resource "aws_ecs_service" "ec2_spot_service" {
  name                               = "ec2-spot-service"
  cluster                            = aws_ecs_cluster.this_ec2.arn
  task_definition                    = aws_ecs_task_definition.streamlit_ec2.arn
  desired_count                      = 1
  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  # EC2 Spot 用 Capacity Provider を明示指定 (デフォルトでもいいが、強制的に Spot にする場合)
  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.ec2_spot_capacity_provider.name
    weight            = 1
    base              = 0
  }

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.ecs_sg.id]
    assign_public_ip = false
  }

  # ALB と連携。ターゲットグループの target_type = "ip" は awsvpc モードのコンテナで有効
  load_balancer {
    target_group_arn = aws_lb_target_group.ec2_spot.arn
    container_name   = "streamlit"
    container_port   = 8080
  }

  # 例: 新タスクが起動して ALB のヘルスチェックに成功してから古いタスクを落とす
  deployment_controller {
    type = "ECS"
  }

  depends_on = [
    aws_ecs_cluster_capacity_providers.this,
    aws_lb_listener_rule.ec2_spot_rule
  ]
}
