provider "aws" {
  region  = "ap-northeast-1" # 必要に応じてリージョンを変更してください
  profile = var.aws_profile
}

terraform {
  backend "local" {
    path = ".cache/terraform.tfstate"
  }
}

variable "aws_profile" {
  type = string
  description = "AWS Profile"
}

# 外部から与えられるパブリックサブネットのID
variable "public_subnet_ids" {
  type        = list(string)
  description = "ALBを配置するパブリックサブネットのリスト"
}

# 外部から与えられるプライベートサブネットのID
variable "private_subnet_ids" {
  type        = list(string)
  description = "ECSを配置するプライベートサブネットのリスト"
}

variable "vpc_id" {
  type        = string
  description = "VPC の ID"
}

# Route53 ドメイン関係
variable "hosted_zone_name" {
  type        = string
  description = "既存の Route53 Hosted Zone 名 (ex: example.com.)"
}

# ACM 証明書 ARN (*.example.comのようにワイルドカードつけてリクエストしておく)
variable "acm_certificate_arn" {
  type        = string
  description = "既に登録済みの ACM 証明書 ARN（東京リージョン）"
}