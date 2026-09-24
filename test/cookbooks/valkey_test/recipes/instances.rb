#
# Cookbook:: valkey_test
# Recipe:: instances
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

# The packaged server next to two instances with settings it could not share
osl_valkey 'default' do
  bind '127.0.0.1'
end

osl_valkey 'cache' do
  instance true
  port 6380
  bind '127.0.0.1'
  firewall false
  maxmemory '64mb'
  maxmemory_policy 'allkeys-lru'
  save ''
end

osl_valkey 'locks' do
  instance true
  port 6381
  pass 'valkey-test'
  appendonly true
  maxmemory_policy 'noeviction'
end
