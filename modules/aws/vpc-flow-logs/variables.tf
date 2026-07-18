variable "vpc_id" {
  description = "VPC the flow log captures traffic for."
  type        = string
}

variable "log_group_name" {
  description = "CloudWatch log group name the flow log writes to (e.g. /aws/vpc-flow-logs/<environment>)."
  type        = string
}

variable "role_name" {
  description = "Name of the IAM role the flow-log service assumes to write to the log group. Also names the inline log-write policy."
  type        = string
}

variable "retention_in_days" {
  description = "CloudWatch log-group retention for the flow-log records."
  type        = number
  default     = 30
}

variable "traffic_type" {
  description = "Traffic captured by the flow log (ALL, ACCEPT, or REJECT)."
  type        = string
  default     = "ALL"

  validation {
    condition     = contains(["ALL", "ACCEPT", "REJECT"], var.traffic_type)
    error_message = "traffic_type must be one of ALL, ACCEPT, or REJECT."
  }
}

variable "tags" {
  description = "Tags applied to the flow log, log group, and IAM role."
  type        = map(string)
  default     = {}
}
