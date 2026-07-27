#
# Cookbook:: valkey_test
# Recipe:: replica
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

# A clustered member shape (spec-only): replica of a primary, with the
# split-brain write guard a multi-node deployment should carry.
osl_valkey 'default' do
  pass 'valkey-test'
  replicaof 'valkey1.example.org'
  min_replicas_to_write 1
  min_replicas_max_lag 5
end
