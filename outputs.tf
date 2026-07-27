output "chef_zero" {
    value = "${openstack_compute_instance_v2.chef_zero.network.0.fixed_ip_v4}"
}
output "valkey1" {
    value = "${openstack_compute_instance_v2.valkey1.network.0.fixed_ip_v4}"
}
output "valkey2" {
    value = "${openstack_compute_instance_v2.valkey2.network.0.fixed_ip_v4}"
}
output "valkey3" {
    value = "${openstack_compute_instance_v2.valkey3.network.0.fixed_ip_v4}"
}
