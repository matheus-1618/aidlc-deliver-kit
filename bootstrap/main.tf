# AI-DLC Deliver Kit — bootstrap da conta alvo
#
# Cria o mínimo que a conta ALVO precisa para o fluxo idea→deploy:
#   1. (opcional) o OIDC provider do GitHub Actions
#   2. a role de deploy que os workflows assumem — trust POR REPO (least privilege)
#   3. o bucket de tfstate dos ambientes provisionados
#
# A credencial de deploy NUNCA sai desta conta: o GitHub Actions assume a role
# via OIDC; a plataforma AI-DLC nunca vê chave nenhuma.
#
# Uso:
#   terraform init && terraform apply \
#     -var 'github_repos=["sua-org/seu-repo"]' \
#     -var create_oidc_provider=false   # true se a conta ainda não tem o provider

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws    = { source = "hashicorp/aws", version = ">= 5.0" }
    random = { source = "hashicorp/random", version = ">= 3.0" }
  }
}

variable "aws_region" {
  type    = string
  default = "us-west-2"
}

variable "github_repos" {
  description = "Repos autorizados a assumir a role (formato org/repo)"
  type        = list(string)
}

variable "create_oidc_provider" {
  description = "Criar o OIDC provider do GitHub (false se a conta já tem)"
  type        = bool
  default     = false
}

variable "project_tag" {
  description = "Tag Project aplicada e exigida em tudo que o fluxo cria"
  type        = string
  default     = "aidlc-deliver"
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project   = var.project_tag
      ManagedBy = "aidlc-deliver-kit"
    }
  }
}

data "aws_caller_identity" "current" {}

# --- 1. OIDC provider (condicional) -----------------------------------------
resource "aws_iam_openid_connect_provider" "github" {
  count           = var.create_oidc_provider ? 1 : 0
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  # Thumbprint não é mais verificado pela AWS para este provider, mas o campo é obrigatório.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

locals {
  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"
}

# --- 2. Role de deploy --------------------------------------------------------
resource "aws_iam_role" "deploy" {
  name = "aidlc-deliver-github-actions"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
        # Cobre as duas formas do sub claim: a clássica (repo:org/repo:...) e a
        # de subject imutável (repo:org@ID/repo@ID:...) que repos novos podem
        # ter habilitada (use_immutable_subject). Cheque a sua com:
        #   gh api repos/ORG/REPO/actions/oidc/customization/sub
        StringLike = { "token.actions.githubusercontent.com:sub" = flatten([
          for r in var.github_repos : [
            "repo:${r}:*",
            "repo:${split("/", r)[0]}@*/${split("/", r)[1]}@*:*",
          ]
        ]) }
      }
    }]
  })
}

# Escopo do flavor static-site: S3 (buckets do fluxo), CloudFront, auditoria por
# tag e o state. Flavors maiores (three-tier) acrescentam statements aqui.
resource "aws_iam_role_policy" "deploy" {
  name = "deliver-static-site"
  role = aws_iam_role.deploy.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "SiteBuckets"
        Effect   = "Allow"
        Action   = "s3:*"
        Resource = ["arn:aws:s3:::deliver-*", "arn:aws:s3:::deliver-*/*"]
      },
      {
        Sid    = "CloudFront"
        Effect = "Allow"
        Action = [
          "cloudfront:CreateDistribution", "cloudfront:UpdateDistribution",
          "cloudfront:DeleteDistribution", "cloudfront:GetDistribution",
          "cloudfront:GetDistributionConfig", "cloudfront:ListDistributions",
          "cloudfront:TagResource", "cloudfront:UntagResource", "cloudfront:ListTagsForResource",
          "cloudfront:CreateOriginAccessControl", "cloudfront:DeleteOriginAccessControl",
          "cloudfront:GetOriginAccessControl", "cloudfront:UpdateOriginAccessControl",
          "cloudfront:CreateInvalidation"
        ]
        Resource = "*"
      },
      {
        Sid      = "TagAudit"
        Effect   = "Allow"
        Action   = ["tag:GetResources"]
        Resource = "*"
      },
      {
        # Flavor lambda-backend: a função, seu log group e a role de execução —
        # tudo confinado ao prefixo deliver-.
        Sid      = "LambdaBackend"
        Effect   = "Allow"
        Action   = ["lambda:*"]
        Resource = "arn:aws:lambda:*:${data.aws_caller_identity.current.account_id}:function:deliver-*"
      },
      {
        Sid      = "LambdaLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:DescribeLogGroups", "logs:PutRetentionPolicy", "logs:TagResource", "logs:ListTagsForResource", "logs:ListTagsLogGroup"]
        Resource = "arn:aws:logs:*:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/deliver-*"
      },
      {
        Sid    = "LambdaExecRole"
        Effect = "Allow"
        Action = [
          "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:TagRole",
          "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy", "iam:ListRolePolicies",
          "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:ListAttachedRolePolicies",
          "iam:ListInstanceProfilesForRole", "iam:PassRole"
        ]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/deliver-*"
      },
      {
        Sid      = "TfState"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.tfstate.arn, "${aws_s3_bucket.tfstate.arn}/*"]
      }
    ]
  })
}

# --- 3. Bucket de tfstate dos ambientes ---------------------------------------
resource "random_id" "suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "tfstate" {
  bucket        = "aidlc-deliver-tfstate-${random_id.suffix.hex}"
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- Saídas que os workflows dos repos consomem -------------------------------
output "deploy_role_arn" {
  value = aws_iam_role.deploy.arn
}

output "tfstate_bucket" {
  value = aws_s3_bucket.tfstate.bucket
}

output "aws_region" {
  value = var.aws_region
}
