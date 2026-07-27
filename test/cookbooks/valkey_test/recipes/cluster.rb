#
# Cookbook:: valkey_test
# Recipe:: cluster
#
# Copyright:: 2026, Oregon State University
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# One run list for every member: the seeded role comes from comparing
# this node's hostname to the configured primary, so the same recipe
# converges the primary and its replicas.
primary_ip = node['valkey_test']['primary_ip']
replica = node['hostname'] != node['valkey_test']['primary_host']

osl_valkey 'default' do
  pass node['valkey_test']['pass']
  replicaof primary_ip if replica
  appendonly true
  maxmemory_policy 'noeviction'
  # Set on every member, not just the seeded primary: whichever node
  # sentinel promotes must also refuse writes once it is alone.
  min_replicas_to_write 1
end

osl_valkey_sentinel node['valkey_test']['service_name'] do
  monitor_host primary_ip
  quorum node['valkey_test']['quorum']
  pass node['valkey_test']['pass']
end
