variable "instance_type" {
  description = "instance size for docker server"
  type = string
  default = "t2.micro"
}

variable "path" {
  description = "private key"
  default = "dockerkey"
}