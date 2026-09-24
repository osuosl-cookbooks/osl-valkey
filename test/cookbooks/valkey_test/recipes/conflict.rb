#
# Cookbook:: valkey_test
# Recipe:: conflict
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

# Spec-only: pairs of declarations the conflict guard must reject or accept
case node['valkey_test']['conflict']
when 'settings'
  osl_valkey 'first' do
    maxmemory '1gb'
  end

  osl_valkey 'second' do
    maxmemory '2gb'
  end
when 'port'
  osl_valkey 'first'

  osl_valkey 'second' do
    instance true
  end
when 'name'
  osl_valkey 'sentinel' do
    instance true
    port 6380
  end
when 'long'
  osl_valkey 'a-name-that-is-22-long' do
    instance true
    port 6380
  end
else
  osl_valkey 'first' do
    config('maxmemory' => '2gb', 'save' => '""')
  end

  osl_valkey 'second' do
    maxmemory '2gb'
    save ''
  end
end
