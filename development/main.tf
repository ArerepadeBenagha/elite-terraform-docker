###########------ Nginx Server -----########
resource "aws_instance" "nginxserver" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.main-public-1.id
  key_name               = aws_key_pair.mykeypair.key_name
  vpc_security_group_ids = [aws_security_group.ec2-sg.id]

  connection {
    # The default username for our AMI
    user        = "ubuntu"
    host        = self.public_ip
    type        = "ssh"
    private_key = file(var.path)
  }
  provisioner "remote-exec" {
    inline = [
      "sudo apt-get -y update",
      "sudo apt install nginx -y",
      # "sudo apt install apache2 -y",
      # "sudo systemctl start apache2",
    ]
  }
  tags = merge(local.common_tags,
    { Name = "nginx-server"
  Application = "public" })
}

###-------- ALB -------###
resource "aws_lb" "nginxlb" {
  name               = join("-", [local.application.app_name, "nginxlb"])
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.main-alb.id]
  subnets            = [aws_subnet.main-public-1.id, aws_subnet.main-public-2.id]
  idle_timeout       = "60"

  access_logs {
    bucket  = aws_s3_bucket.logs_s3dev.bucket
    prefix  = join("-", [local.application.app_name, "nginxlb-s3logs"])
    enabled = true
  }
  tags = merge(local.common_tags,
    { Name = "nginxserver"
  Application = "public" })
}

///////////////
resource "aws_wafv2_web_acl_association" "example" {
  resource_arn = aws_lb.nginxlb.arn
  web_acl_arn  = aws_wafv2_web_acl.test.arn
}

###------- ALB Health Check -------###
resource "aws_lb_target_group" "nginxapp_tglb" {
  name     = join("-", [local.application.app_name, "nginxapptglb"])
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/"
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = "5"
    unhealthy_threshold = "2"
    timeout             = "5"
    interval            = "30"
    matcher             = "200"
  }
}

resource "aws_lb_target_group_attachment" "nginxapp_tglbat" {
  target_group_arn = aws_lb_target_group.nginxapp_tglb.arn
  target_id        = aws_instance.nginxserver.id
  port             = 80
}

####-------- SSL Cert ------#####
resource "aws_lb_listener" "nginxapp_lblist2" {
  load_balancer_arn = aws_lb.nginxlb.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS-1-2-2017-01"
  certificate_arn   = "arn:aws:acm:us-east-1:901445516958:certificate/38e7fca6-b2fb-43ab-b31f-cbb47459a2f4"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.nginxapp_tglb.arn
  }
}
####---- Redirect Rule -----####
resource "aws_lb_listener" "nginxapp_lblist" {
  load_balancer_arn = aws_lb.nginxlb.arn
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

########------- S3 Bucket -----------####
resource "aws_s3_bucket" "logs_s3dev" {
  bucket = join("-", [local.application.app_name, "logdev"])
  acl    = "private"

  tags = merge(local.common_tags,
    { Name = "nginxserver"
  bucket = "private" })
}
resource "aws_s3_bucket_policy" "logs_s3dev" {
  bucket = aws_s3_bucket.logs_s3dev.id

  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "MYBUCKETPOLICY"
    Statement = [
      {
        Sid       = "Allow"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.logs_s3dev.arn,
          "${aws_s3_bucket.logs_s3dev.arn}/*",
        ]
        Condition = {
          NotIpAddress = {
            "aws:SourceIp" = "8.8.8.8/32"
          }
        }
      },
    ]
  })
}

#IAM
resource "aws_iam_role" "nginx_role" {
  name = join("-", [local.application.app_name, "nginxrole"])

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Sid    = ""
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })

  tags = merge(local.common_tags,
    { Name = "nginxserver"
  Role = "nginxrole" })
}

#######------- IAM Role ------######
resource "aws_iam_role_policy" "nginx_policy" {
  name = join("-", [local.application.app_name, "nginxpolicy"])
  role = aws_iam_role.nginx_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "ec2:Describe*",
        ]
        Effect   = "Allow"
        Resource = "*"
      },
    ]
  })
}

#####------ Certificate -----------####
resource "aws_acm_certificate" "nginxcert" {
  domain_name       = "*.elietesolutionsit.de"
  validation_method = "DNS"
  lifecycle {
    create_before_destroy = true
  }
  tags = merge(local.common_tags,
    { Name = "registration-app.elietesolutionsit.de"
  Cert = "nginxcert" })
}

###------- Cert Validation -------###
data "aws_route53_zone" "main-zone" {
  name         = "elietesolutionsit.de"
  private_zone = false
}

resource "aws_route53_record" "nginxzone_record" {
  for_each = {
    for dvo in aws_acm_certificate.nginxcert.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.main-zone.zone_id
}

resource "aws_acm_certificate_validation" "nginxcert" {
  certificate_arn         = aws_acm_certificate.nginxcert.arn
  validation_record_fqdns = [for record in aws_route53_record.nginxzone_record : record.fqdn]
}

##------- ALB Alias record ----------##
resource "aws_route53_record" "www" {
  zone_id = data.aws_route53_zone.main-zone.zone_id
  name    = "registration-app.elietesolutionsit.de"
  type    = "A"

  alias {
    name                   = aws_lb.nginxlb.dns_name
    zone_id                = aws_lb.nginxlb.zone_id
    evaluate_target_health = true
  }
}