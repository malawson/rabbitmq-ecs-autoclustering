variable "service_name" {
  type        = "string"
  description = "name of the service to deploy"
}

variable "ecs_sd_alias" {
  type        = "string"
  description = "ecs service discover namespace stack alias"
  default     = "ecs-sd-namespace-pa"
}

variable "cluster_alias" {
  type        = "string"
  description = "ecs cluster alias"
}

variable "retention_in_days" {
  type        = "string"
  description = "number of days to keep logs"
  default     = 7
}

variable "vpc_alias" {
  type        = "string"
  description = "ecs vpc alias"
}

## Service level parameters
variable "cpu" {
  description = "amount of reserved cpu"
  default     = 500
}

variable "memory" {
  description = "amount of memory to allocate"
  default     = 128
}

variable "artifact_version" {
  type        = "string"
  description = "semver tagged artifact to deploy"
}

variable "desired_count" {
  type        = "string"
  description = "number of containers to launch"
  default     = 3
}

##Boiler plate
variable "env" {
  type = "string"
}

variable "account" {
  type = "string"
}

variable "region" {
  type = "string"
}

variable "lock_table" {
  type = "map"
}

variable "remote_state" {
  type = "map"
}
