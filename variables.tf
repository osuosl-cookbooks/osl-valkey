variable "docker_image" {
    default = "AlmaLinux 9 (docker)"
}
variable "os_image" {
    type = string
}
variable "ssh_key_name" {
    default = "bootstrap"
}
variable "ssh_user_name" {
    default = "almalinux"
}
variable "network" {
    default = "backend"
}
variable "chef_version" {
    default = "18"
}
