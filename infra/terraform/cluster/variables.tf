variable aws_region {
    description = "AWS region to beploy into"
    type = string
    default = "ap-south-2"
}

variable project_name {
    description = "Prefix used for naming/tagging every resource, so it's obvious what created them"
    type = string
    default = "voting-app"
}

variable "cluster_name" {
  description = "Name of the EKS cluster (used later, referenced now for subnet tagging)"
  type        = string
  default     = "voting-app"
}