locals {
  aws_region   = "ap-northeast-1"     # REGION
  vpc_name     = "karpenter-test-vpc" # VPC NAME
  cluster_name = "karpenter-test"     # EKS CLUSTER NAME
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "3.14.2"

  # VPC NAME
  name = local.vpc_name

  # VPC CIDR
  cidr = "10.0.0.0/16"

  # SUBNET
  azs             = ["ap-northeast-1a", "ap-northeast-1c"]
  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets = ["10.0.3.0/24", "10.0.4.0/24"]

  # INTERNET GATEWAY
  create_igw = true

  # NAT GATEWAY
  enable_nat_gateway = true
  single_nat_gateway = true

  # DNS
  enable_dns_hostnames = true
  enable_dns_support   = true


  #
  # Subnet Auto Discovery
  # https://kubernetes-sigs.github.io/aws-load-balancer-controller/v2.4/deploy/subnet_discovery/
  #
  public_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                      = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"             = "1"
    # Tags subnets for Karpenter auto-discovery
    "karpenter.sh/discovery" = local.cluster_name
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "18.27.1"

  # EKS CONTROL PLANE 
  cluster_name = local.cluster_name

  # 
  # Kubernetes 1.22
  # https://docs.aws.amazon.com/ja_jp/eks/latest/userguide/kubernetes-versions.html#kubernetes-1.22
  #
  cluster_version = "1.22"

  #
  # Amazon EKS クラスターエンドポイントアクセスコントロール
  # https://docs.aws.amazon.com/ja_jp/eks/latest/userguide/cluster-endpoint.html
  #
  cluster_endpoint_private_access = false
  cluster_endpoint_public_access  = true

  #
  # Amazon EKS コントロールプレーンのログ記録
  # https://docs.aws.amazon.com/ja_jp/eks/latest/userguide/control-plane-logs.html 
  #
  cluster_enabled_log_types = ["audit", "api", "authenticator"]

  #
  # Amazon EKS アドオン
  # https://docs.aws.amazon.com/ja_jp/eks/latest/userguide/eks-add-ons.html
  #
  cluster_addons = {

    #
    # CoreDNS アドオンの管理
    # https://docs.aws.amazon.com/ja_jp/eks/latest/userguide/managing-coredns.html
    #
    coredns = {
      resolve_conflicts = "OVERWRITE"
    }

    #
    # kube-proxy アドオンの管理
    # https://docs.aws.amazon.com/ja_jp/eks/latest/userguide/managing-kube-proxy.html
    #
    kube-proxy = {}

    #
    # Amazon VPC CNI Plugin for Kubernetes を使用したAmazon EKS での Pod ネットワーク
    # https://docs.aws.amazon.com/ja_jp/eks/latest/userguide/pod-networking.html
    #
    vpc-cni = {
      resolve_conflicts = "OVERWRITE"
    }
  }

  # EKS CLUSTER VPC AND SUBNETS
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  #
  # マネージド型ノードグループ
  # https://docs.aws.amazon.com/ja_jp/eks/latest/userguide/managed-node-groups.html
  #
  eks_managed_node_groups = {
    karpenter-test = {
      node_group_name = "managed-ondemand"

      instance_types = ["m5.large"]

      min_size     = 1
      max_size     = 1
      desired_size = 1

      create_security_group = false

      iam_role_additional_policies = [
        "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      ]

      tags = {
        # This will tag the launch template created for use by Karpenter
        "karpenter.sh/discovery" = local.cluster_name
      }
    }
  }

  node_security_group_additional_rules = {
    # Extend node-to-node security group rules. Recommended and required for the Add-ons
    ingress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
    # Recommended outbound traffic for Node groups
    egress_all = {
      description      = "Node all egress"
      protocol         = "-1"
      from_port        = 0
      to_port          = 0
      type             = "egress"
      cidr_blocks      = ["0.0.0.0/0"]
      ipv6_cidr_blocks = ["::/0"]
    }

    ingress_cluster_to_node_all_traffic = {
      description                   = "Cluster API to Nodegroup all traffic"
      protocol                      = "-1"
      from_port                     = 0
      to_port                       = 0
      type                          = "ingress"
      source_cluster_security_group = true
    }
  }

  node_security_group_tags = {
    # NOTE - if creating multiple security groups with this module, only tag the
    # security group that Karpenter should utilize with the following tag
    # (i.e. - at most, only one security group should have this tag in your account)
    "karpenter.sh/discovery" = local.cluster_name
  }
}

data "aws_eks_cluster" "cluster" {
  name = module.eks.cluster_id
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_id
}

#
# AWS Load Balancer Controller IRSA
#
module "load_balancer_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.3.0"

  role_name = "load-balancer-controller-${local.cluster_name}"

  attach_load_balancer_controller_policy = true

  oidc_providers = {
    ex = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "kubernetes_service_account" "aws_loadbalancer_controller" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
    annotations = {
      "eks.amazonaws.com/role-arn" = module.load_balancer_controller_irsa.iam_role_arn
    }
  }
}

#
# Karpenter IRSA
#
module "karpenter_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.3.0"

  role_name = "karpenter-controller-${local.cluster_name}"

  attach_karpenter_controller_policy = true
  karpenter_tag_key                  = "karpenter.sh/discovery"

  karpenter_controller_cluster_id = module.eks.cluster_id

  karpenter_controller_node_iam_role_arns = [
    module.eks.eks_managed_node_groups[local.cluster_name].iam_role_arn
  ]

  oidc_providers = {
    ex = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["karpenter:karpenter"]
    }
  }
}

resource "kubernetes_namespace" "karpenter" {
  metadata {
    name = "karpenter"
  }
}

resource "kubernetes_service_account" "karpenter" {
  metadata {
    name      = "karpenter"
    namespace = "karpenter"

    annotations = {
      "eks.amazonaws.com/role-arn" = module.karpenter_irsa.iam_role_arn
    }
  }
}

resource "aws_iam_instance_profile" "karpenter" {
  name = "KarpenterNodeInstanceProfile-${local.cluster_name}"
  role = module.eks.eks_managed_node_groups[local.cluster_name].iam_role_name
}
