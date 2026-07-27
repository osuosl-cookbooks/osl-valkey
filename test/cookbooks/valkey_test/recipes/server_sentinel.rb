#
# Cookbook:: valkey_test
# Recipe:: server_sentinel
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

# A standalone authed server with lock-service settings, monitored by
# a local sentinel: the single-node shape of a distributed-lock tier.
osl_valkey 'default' do
  pass 'valkey-test'
  # Everything here is local, so this also covers the bind property.
  bind '127.0.0.1'
  appendonly true
  maxmemory_policy 'noeviction'
  config('tcp-keepalive' => 60)
end

# Non-default timings so the suite proves these properties reach the
# running sentinel, not just the defaults.
osl_valkey_sentinel 'testlocks' do
  pass 'valkey-test'
  down_after_ms 3000
  failover_timeout_ms 30000
end
