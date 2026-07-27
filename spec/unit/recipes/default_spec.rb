require_relative '../../spec_helper'

describe 'osl-valkey::default' do
  ALL_PLATFORMS.each do |p|
    context "#{p[:platform]} #{p[:version]}" do
      cached(:chef_run) do
        ChefSpec::SoloRunner.new(
          p.dup.merge(step_into: %w(osl_valkey))
        ).converge(described_recipe)
      end

      it 'converges successfully' do
        expect { chef_run }.to_not raise_error
      end

      it { is_expected.to create_osl_valkey 'default' }
      it { is_expected.to accept_osl_firewall_port('valkey').with(ports: %w(6379), osl_only: true) }
      it { is_expected.to install_package 'valkey' }
      it { is_expected.to enable_service 'valkey' }
      it { is_expected.to start_service 'valkey' }

      it do
        is_expected.to create_template('/etc/valkey/valkey.conf').with(
          owner: 'valkey',
          group: 'valkey',
          mode: '0640',
          sensitive: true
        )
      end
      it { is_expected.to render_file('/etc/valkey/valkey.conf').with_content(/^port 6379$/) }
      it { is_expected.to render_file('/etc/valkey/valkey.conf').with_content(/^appendonly no$/) }
      it { is_expected.to_not render_file('/etc/valkey/valkey.conf').with_content(/^requirepass/) }
      it { is_expected.to_not render_file('/etc/valkey/valkey.conf').with_content(/^replicaof/) }
      it { is_expected.to_not render_file('/etc/valkey/valkey.conf').with_content(/^bind/) }
      it { is_expected.to_not render_file('/etc/valkey/valkey.conf').with_content(/^maxmemory-policy/) }
      it { is_expected.to create_file('/etc/valkey/.valkey.conf.chef').with(content: "1\n") }
    end
  end
end
