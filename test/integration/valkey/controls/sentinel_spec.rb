# Every sentinel, plus the operator tooling osl_valkey_sentinel
# installs alongside it. Assertions about which member is currently
# primary live in the cluster/primary controls, not here.
pass = input('valkey_pass', value: '').to_s
service = input('service_name', value: 'testlocks').to_s
sentinel_port = input('sentinel_port', value: 26379).to_s
monitor_port = input('valkey_port', value: 6379).to_s
quorum = input('quorum', value: 1).to_s
down_after_ms = input('down_after_ms', value: 5000).to_s
failover_timeout_ms = input('failover_timeout_ms', value: 60000).to_s
parallel_syncs = input('parallel_syncs', value: 1).to_s
# How many sentinels and replicas this member should see.
sentinel_count = input('sentinel_count', value: 1).to_i
sentinel_replicas = input('sentinel_replicas', value: 0).to_s
config_version = input('config_version', value: 1).to_s
sentinel_requirepass = input('sentinel_requirepass', value: '').to_s

control 'sentinel' do
  describe service('valkey-sentinel') do
    it { should be_enabled }
    it { should be_running }
  end

  describe port(sentinel_port.to_i) do
    it { should be_listening }
    its('protocols') { should include 'tcp' }
  end

  # As with valkey.conf, the mode chef set is not asserted: sentinel
  # rewrites this file constantly and the rewrite lands at 0644. The
  # auth-pass in it is contained by the /etc/valkey directory, which
  # the 'server' control checks.
  describe file('/etc/valkey/sentinel.conf') do
    it { should be_owned_by 'valkey' }
    it { should be_grouped_into 'valkey' }
    # Preserved across the rewrites sentinel makes at runtime.
    its('content') { should match(/^sentinel deny-scripts-reconfig yes$/) }
    its('content') { should match(/^sentinel resolve-hostnames yes$/) }
    its('content') { should match(/^sentinel announce-hostnames yes$/) }
  end

  describe file('/etc/valkey/.sentinel.conf.chef') do
    its('content') { should match(/^#{config_version}$/) }
  end

  # Whether sentinel demands a password from its own clients. Sentinel
  # supports it; the OpenStack lock tier leaves it off because tooz
  # 2.10.1 cannot send one, and relies on the firewall instead.
  if sentinel_requirepass.empty?
    describe command("valkey-cli -p #{sentinel_port} ping") do
      its('stdout') { should match(/^PONG$/) }
    end
  else
    describe command("valkey-cli -p #{sentinel_port} ping") do
      its('stdout') { should match(/NOAUTH/) }
    end
    describe command("REDISCLI_AUTH='#{sentinel_requirepass}' valkey-cli -p #{sentinel_port} ping") do
      its('stdout') { should match(/^PONG$/) }
    end
  end

  # The monitor settings chef seeded, read back from the running
  # sentinel rather than the file it rewrites.
  describe command("valkey-cli -p #{sentinel_port} sentinel master #{service}") do
    its('exit_status') { should eq 0 }
    its('stdout') { should match(/^name\n#{Regexp.escape(service)}$/) }
    its('stdout') { should match(/^port\n#{monitor_port}$/) }
    its('stdout') { should match(/^quorum\n#{quorum}$/) }
    its('stdout') { should match(/^down-after-milliseconds\n#{down_after_ms}$/) }
    its('stdout') { should match(/^failover-timeout\n#{failover_timeout_ms}$/) }
    its('stdout') { should match(/^parallel-syncs\n#{parallel_syncs}$/) }
    its('stdout') { should match(/^num-slaves\n#{sentinel_replicas}$/) }
    its('stdout') { should match(/^num-other-sentinels\n#{sentinel_count - 1}$/) }
  end

  # Quorum and failover authorization are reachable from this member.
  describe command("valkey-cli -p #{sentinel_port} sentinel ckquorum #{service}") do
    its('exit_status') { should eq 0 }
    its('stdout') { should match(/^OK #{sentinel_count} usable Sentinels/) }
  end

  # Operator tooling ships with the sentinel and works against it.
  describe file('/usr/local/lib/valkey_tools.rb') do
    it { should be_file }
    its('mode') { should cmp '0644' }
  end

  %w(valkey-status valkey-failover).each do |tool|
    describe file("/usr/local/bin/#{tool}") do
      it { should be_file }
      its('mode') { should cmp '0755' }
    end
  end

  describe command('/usr/local/bin/valkey-status') do
    its('exit_status') { should eq 0 }
    its('stdout') { should match(/^Service:  #{Regexp.escape(service)}$/) }
    its('stdout') { should match(/ckquorum: OK/) }
    its('stdout') { should_not match(/DOWN or unreachable/) }
  end

  describe command('/usr/local/bin/valkey-failover --help') do
    its('exit_status') { should eq 0 }
    its('stdout') { should match(/Usage: valkey-failover/) }
  end

  # The status tool reads the password out of the seeded config, so it
  # reports live replication state rather than an auth error.
  describe command('/usr/local/bin/valkey-status') do
    its('stdout') { should match(/^\S+:#{monitor_port}\s+(master|replica)\s/) }
  end unless pass.empty?
end
