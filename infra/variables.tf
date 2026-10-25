variable "region" {
  description = "AWS region for every resource in this lab (your project is pinned to Sydney)"
  type        = string
  default     = "ap-southeast-2"
}

variable "project" {
  description = "Name prefix and tag value for all resources"
  type        = string
  default     = "netflow-lab"
}

variable "my_ip" {
  description = "Your public IP in CIDR form, e.g. 203.0.113.10/32. Only this IP can open Grafana and the Flink UI."
  type        = string
}

variable "instance_type" {
  description = "EC2 size for the Docker stack. Needs ~8 GB RAM for Kafka + Flink + Postgres + Grafana."
  type        = string
  default     = "m7i-flex.large" # 2 vCPU, 8 GiB
}
