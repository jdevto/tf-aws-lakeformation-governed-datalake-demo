variable "tags" {
  description = "Common tags for all resources"
  type        = map(string)
  default = {
    Project     = "LakeFormationDemo"
    Environment = "Demo"
  }
}

variable "enable_lakeformation_governance" {
  description = "Enable Lake Formation governance features (tags, filters, grants). Requires Lake Formation admin permissions."
  type        = bool
  default     = false
}
