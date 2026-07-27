require_relative '../../spec_helper'

describe 'valkey_test::server_sentinel' do
  ALL_PLATFORMS.each do |p|
    context "#{p[:platform]} #{p[:version]}" do
      cached(:chef_run) do
        ChefSpec::SoloRunner.new(
          p.dup.merge(step_into: %w(osl_valkey osl_valkey_sentinel))
        ).converge(described_recipe)
      end

      it 'converges successfully' do
        expect { chef_run }.to_not raise_error
      end

      it do
        is_expected.to create_osl_valkey('default').with(
          pass: 'valkey-test',
          bind: '127.0.0.1',
          appendonly: true,
          maxmemory_policy: 'noeviction',
          config: { 'tcp-keepalive' => 60 }
        )
      end
      it do
        is_expected.to create_osl_valkey_sentinel('testlocks').with(
          pass: 'valkey-test',
          monitor_host: '127.0.0.1',
          quorum: 1,
          down_after_ms: 3000,
          failover_timeout_ms: 30_000
        )
      end

      it { is_expected.to accept_osl_firewall_port('valkey').with(ports: %w(6379), osl_only: true) }
      it { is_expected.to accept_osl_firewall_port('valkey_sentinel').with(ports: %w(26379), osl_only: true) }
      it { is_expected.to install_package 'valkey' }
      it { is_expected.to apply_sysctl('vm.overcommit_memory').with(value: '1') }

      %w(valkey valkey-sentinel).each do |svc|
        it { is_expected.to enable_service svc }
        it { is_expected.to start_service svc }
      end

      it do
        expect(chef_run.template('/etc/valkey/valkey.conf')).to \
          notify('service[valkey]').to(:restart).immediately
      end
      it { is_expected.to render_file('/etc/valkey/valkey.conf').with_content(/^requirepass valkey-test$/) }
      it { is_expected.to render_file('/etc/valkey/valkey.conf').with_content(/^masterauth valkey-test$/) }
      it { is_expected.to render_file('/etc/valkey/valkey.conf').with_content(/^appendonly yes$/) }
      it { is_expected.to render_file('/etc/valkey/valkey.conf').with_content(/^maxmemory-policy noeviction$/) }
      it { is_expected.to render_file('/etc/valkey/valkey.conf').with_content(/^tcp-keepalive 60$/) }
      it { is_expected.to render_file('/etc/valkey/valkey.conf').with_content(/^bind 127\.0\.0\.1$/) }
      it { is_expected.to_not render_file('/etc/valkey/valkey.conf').with_content(/^replicaof/) }
      it { is_expected.to_not render_file('/etc/valkey/valkey.conf').with_content(/^min-replicas-to-write/) }

      it do
        expect(chef_run.template('/etc/valkey/sentinel.conf')).to \
          notify('service[valkey-sentinel]').to(:restart).immediately
      end
      it do
        is_expected.to create_template('/etc/valkey/sentinel.conf').with(
          owner: 'valkey',
          group: 'valkey',
          mode: '0640',
          sensitive: true
        )
      end
      it { is_expected.to render_file('/etc/valkey/sentinel.conf').with_content(/^port 26379$/) }
      # No requirepass set, so sentinel takes any client the firewall
      # admits; the template says so rather than claiming auth is
      # impossible.
      it { is_expected.to render_file('/etc/valkey/sentinel.conf').with_content(/^protected-mode no$/) }
      it { is_expected.to_not render_file('/etc/valkey/sentinel.conf').with_content(/^requirepass/) }
      it { is_expected.to_not render_file('/etc/valkey/sentinel.conf').with_content(/^bind/) }
      it { is_expected.to render_file('/etc/valkey/sentinel.conf').with_content(/^sentinel deny-scripts-reconfig yes$/) }
      it { is_expected.to render_file('/etc/valkey/sentinel.conf').with_content(/^sentinel resolve-hostnames yes$/) }
      it { is_expected.to render_file('/etc/valkey/sentinel.conf').with_content(/^sentinel monitor testlocks 127\.0\.0\.1 6379 1$/) }
      it { is_expected.to render_file('/etc/valkey/sentinel.conf').with_content(/^sentinel auth-pass testlocks valkey-test$/) }
      it { is_expected.to render_file('/etc/valkey/sentinel.conf').with_content(/^sentinel down-after-milliseconds testlocks 3000$/) }
      it { is_expected.to render_file('/etc/valkey/sentinel.conf').with_content(/^sentinel failover-timeout testlocks 30000$/) }
      it { is_expected.to render_file('/etc/valkey/sentinel.conf').with_content(/^sentinel parallel-syncs testlocks 1$/) }

      %w(/etc/valkey/.valkey.conf.chef /etc/valkey/.sentinel.conf.chef).each do |marker|
        it { is_expected.to create_file(marker).with(content: "1\n") }
      end

      it { is_expected.to create_cookbook_file('/usr/local/lib/valkey_tools.rb').with(mode: '0644') }
      %w(valkey-status valkey-failover).each do |tool|
        it { is_expected.to create_cookbook_file("/usr/local/bin/#{tool}").with(mode: '0755') }
      end

      # Seed-once guard: a marker at the current config_version leaves
      # both configs alone, since the daemons own them at runtime.
      context 'already seeded' do
        cached(:chef_run) do
          ChefSpec::SoloRunner.new(
            p.dup.merge(step_into: %w(osl_valkey osl_valkey_sentinel))
          ).converge(described_recipe)
        end

        before do
          allow(File).to receive(:exist?).and_call_original
          allow(File).to receive(:read).and_call_original
          %w(/etc/valkey/.valkey.conf.chef /etc/valkey/.sentinel.conf.chef).each do |marker|
            allow(File).to receive(:exist?).with(marker).and_return(true)
            allow(File).to receive(:read).with(marker).and_return("1\n")
          end
        end

        it { is_expected.to_not create_template '/etc/valkey/valkey.conf' }
        it { is_expected.to_not create_template '/etc/valkey/sentinel.conf' }
      end

      # A bumped config_version re-seeds over a stale marker.
      context 'seeded at an older config_version' do
        cached(:chef_run) do
          ChefSpec::SoloRunner.new(
            p.dup.merge(step_into: %w(osl_valkey osl_valkey_sentinel))
          ).converge(described_recipe)
        end

        before do
          allow(File).to receive(:exist?).and_call_original
          allow(File).to receive(:read).and_call_original
          %w(/etc/valkey/.valkey.conf.chef /etc/valkey/.sentinel.conf.chef).each do |marker|
            allow(File).to receive(:exist?).with(marker).and_return(true)
            allow(File).to receive(:read).with(marker).and_return("0\n")
          end
        end

        it { is_expected.to create_template '/etc/valkey/valkey.conf' }
        it { is_expected.to create_template '/etc/valkey/sentinel.conf' }
      end
    end
  end
end

describe 'valkey_test::sentinel_auth' do
  ALL_PLATFORMS.each do |p|
    context "#{p[:platform]} #{p[:version]}" do
      cached(:chef_run) do
        ChefSpec::SoloRunner.new(
          p.dup.merge(step_into: %w(osl_valkey osl_valkey_sentinel))
        ).converge(described_recipe)
      end

      # Sentinel does support client auth; only clients that cannot send
      # it (tooz) have to go without.
      it do
        is_expected.to create_osl_valkey_sentinel('authlocks').with(
          requirepass: 'sentinel-secret',
          bind: '127.0.0.1'
        )
      end
      it { is_expected.to render_file('/etc/valkey/sentinel.conf').with_content(/^requirepass sentinel-secret$/) }
      it { is_expected.to render_file('/etc/valkey/sentinel.conf').with_content(/^bind 127\.0\.0\.1$/) }
      it { is_expected.to render_file('/etc/valkey/sentinel.conf').with_content(/^protected-mode yes$/) }
      it { is_expected.to_not render_file('/etc/valkey/sentinel.conf').with_content(/^protected-mode no$/) }
    end
  end
end

describe 'valkey_test::replica' do
  ALL_PLATFORMS.each do |p|
    context "#{p[:platform]} #{p[:version]}" do
      cached(:chef_run) do
        ChefSpec::SoloRunner.new(
          p.dup.merge(step_into: %w(osl_valkey))
        ).converge(described_recipe)
      end

      it do
        is_expected.to create_osl_valkey('default').with(
          replicaof: 'valkey1.example.org',
          min_replicas_to_write: 1,
          min_replicas_max_lag: 5
        )
      end
      it { is_expected.to render_file('/etc/valkey/valkey.conf').with_content(/^replicaof valkey1\.example\.org 6379$/) }
      it { is_expected.to render_file('/etc/valkey/valkey.conf').with_content(/^min-replicas-to-write 1$/) }
      it { is_expected.to render_file('/etc/valkey/valkey.conf').with_content(/^min-replicas-max-lag 5$/) }
    end
  end
end
