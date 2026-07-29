#
# Cookbook:: valkey_test
# Recipe:: sentinel_auth
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

# Spec-only: a sentinel that demands a password from its clients and
# listens on one address. The OpenStack lock tier cannot use this
# (tooz 2.10.1 has no way to send it), but sentinel supports it and
# clients that can authenticate should.
osl_valkey 'default' do
  pass 'valkey-test'
  bind '127.0.0.1'
end

osl_valkey_sentinel 'authlocks' do
  pass 'valkey-test'
  requirepass 'sentinel-secret'
  bind '127.0.0.1'
end
