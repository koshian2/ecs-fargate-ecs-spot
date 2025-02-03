# ─────────────────────────────────────────────────────────────
# Route53 のHosted Zone は既存を仮定 (あるいは新規作成でもOK)
# data で取得したり、resource で作成したりする
# ─────────────────────────────────────────────────────────────
data "aws_route53_zone" "main" {
  # 既存のドメインを使う例
  name         = var.hosted_zone_name
  private_zone = false
}

# Aレコード
resource "aws_route53_record" "wildcard_record" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "*.${var.hosted_zone_name}"
  type    = "A"

  alias {
    name                   = aws_lb.alb.dns_name
    zone_id                = aws_lb.alb.zone_id
    evaluate_target_health = false
  }
}
