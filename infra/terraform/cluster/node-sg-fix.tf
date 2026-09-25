resource "aws_security_group_rule" "node_to_node_all" {
  type = "ingress"
  from_port = 0
  to_port = 65535
  protocol = "-1"
  security_group_id = module.eks.node_security_group_id
  source_security_group_id = module.eks.node_security_group_id
  description = "Allow all traffic between nodes needed for cross node Pod traffic on app defined ports outside the modules default minimal rule set"
}
