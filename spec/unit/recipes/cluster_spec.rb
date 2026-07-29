require_relative '../../spec_helper'

# The multi-node run list: one recipe converges every member, picking
# primary or replica by comparing the node's hostname to the configured
# primary. The terraform env in main.tf bootstraps all three nodes with
# this same role.
describe 'valkey_test::cluster' do
  ALL_PLATFORMS.each do |p|
    context "#{p[:platform]} #{p[:version]}" do
      context 'seeded primary' do
        cached(:chef_run) do
          ChefSpec::SoloRunner.new(
            p.dup.merge(step_into: %w(osl_valkey osl_valkey_sentinel))
          ) { |node| node.automatic['hostname'] = 'valkey1' }.converge(described_recipe)
        end

        it do
          is_expected.to create_osl_valkey('default').with(
            pass: 'multi-node-test',
            replicaof: nil,
            appendonly: true,
            maxmemory_policy: 'noeviction',
            min_replicas_to_write: 1
          )
        end

        it { is_expected.to_not render_file('/etc/valkey/valkey.conf').with_content(/^replicaof/) }
        it { is_expected.to render_file('/etc/valkey/valkey.conf').with_content(/^min-replicas-to-write 1$/) }
        it { is_expected.to render_file('/etc/valkey/valkey.conf').with_content(/^appendonly yes$/) }
        it { is_expected.to render_file('/etc/valkey/valkey.conf').with_content(/^maxmemory-policy noeviction$/) }

        it do
          is_expected.to create_osl_valkey_sentinel('testlocks').with(
            monitor_host: '10.1.0.11',
            quorum: 2,
            pass: 'multi-node-test'
          )
        end
        it do
          is_expected.to render_file('/etc/valkey/sentinel.conf')
            .with_content(/^sentinel monitor testlocks 10\.1\.0\.11 6379 2$/)
        end
      end

      context 'replica member' do
        cached(:chef_run) do
          ChefSpec::SoloRunner.new(
            p.dup.merge(step_into: %w(osl_valkey osl_valkey_sentinel))
          ) { |node| node.automatic['hostname'] = 'valkey2' }.converge(described_recipe)
        end

        it { is_expected.to create_osl_valkey('default').with(replicaof: '10.1.0.11') }
        it do
          is_expected.to render_file('/etc/valkey/valkey.conf')
            .with_content(/^replicaof 10\.1\.0\.11 6379$/)
        end
        # Every member carries the guard, so a promoted replica also
        # refuses writes once it is alone.
        it { is_expected.to render_file('/etc/valkey/valkey.conf').with_content(/^min-replicas-to-write 1$/) }
        # Replicas monitor the same primary, so the quorum agrees.
        it do
          is_expected.to render_file('/etc/valkey/sentinel.conf')
            .with_content(/^sentinel monitor testlocks 10\.1\.0\.11 6379 2$/)
        end
      end
    end
  end
end
