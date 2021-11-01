variable "path_to_public_key" {
  description = "public key"
  default     = "dockerkey.pub"
}
variable "instance_type" {
  description = "instance size for docker server"
}
variable "path" {
  description = "private key"
  default     = "dockerkey.pem"
}