# Every valkey server, whatever it was configured with. Values are read
# back from the running server rather than the config file, since the
# daemon rewrites that file itself.
pass = input('valkey_pass', value: '').to_s
port = input('valkey_port', value: 6379).to_s
bind = input('bind', value: '').to_s
appendonly = input('appendonly', value: 'no').to_s
maxmemory_policy = input('maxmemory_policy', value: '').to_s
min_replicas_to_write = input('min_replicas_to_write', value: 0).to_s
min_replicas_max_lag = input('min_replicas_max_lag', value: 10).to_s
# 'directive=value,directive=value' passed through the config property.
extra_config = input('extra_config', value: '').to_s
config_version = input('config_version', value: 1).to_s
auth = pass.empty? ? '' : "REDISCLI_AUTH='#{pass}'"

control 'server' do
  describe package('valkey') do
    it { should be_installed }
  end

  describe service('valkey') do
    it { should be_enabled }
    it { should be_running }
  end

  describe port(port.to_i) do
    it { should be_listening }
    its('protocols') { should include 'tcp' }
  end

  # Seeded config: chef writes it once, then leaves it to the daemon,
  # so the marker records which version was written. The mode chef set
  # is deliberately not asserted - valkey rewrites this file when
  # sentinel changes its replication role, and that rewrite (temp file
  # plus rename) lands at 0644. Ownership survives, and the directory
  # below is what actually contains the password in it.
  describe file('/etc/valkey/valkey.conf') do
    it { should be_owned_by 'valkey' }
    it { should be_grouped_into 'valkey' }
  end

  # The real protection for requirepass and sentinel's auth-pass: no
  # other user can reach either config, whatever mode a daemon rewrite
  # leaves behind.
  describe file('/etc/valkey') do
    it { should be_directory }
    it { should_not be_readable.by('others') }
    it { should_not be_executable.by('others') }
  end

  describe file('/etc/valkey/.valkey.conf.chef') do
    its('content') { should match(/^#{config_version}$/) }
  end

  # Recommended by valkey for background saves and AOF rewrites.
  describe kernel_parameter('vm.overcommit_memory') do
    its('value') { should eq 1 }
  end

  # Auth: either the server requires the configured password, or no
  # password was configured at all.
  if pass.empty?
    describe command('valkey-cli ping') do
      its('stdout') { should match(/^PONG$/) }
    end
  else
    describe command('valkey-cli ping') do
      its('stdout') { should match(/NOAUTH/) }
    end
    describe command("#{auth} valkey-cli ping") do
      its('stdout') { should match(/^PONG$/) }
    end
    describe command("#{auth} valkey-cli config get requirepass") do
      its('stdout') { should match(/^#{Regexp.escape(pass)}$/) }
    end
    # Replicas authenticate to their primary with the same secret, so a
    # demoted ex-primary can resync after a failover.
    describe command("#{auth} valkey-cli config get masterauth") do
      its('stdout') { should match(/^#{Regexp.escape(pass)}$/) }
    end
  end

  {
    'port' => port,
    'appendonly' => appendonly,
    'min-replicas-to-write' => min_replicas_to_write,
    'min-replicas-max-lag' => min_replicas_max_lag,
    'protected-mode' => 'yes',
    'dir' => '/var/lib/valkey',
  }.each do |directive, expected|
    describe command("#{auth} valkey-cli config get #{directive}") do
      its('stdout') { should match(/^#{Regexp.escape(expected)}$/) }
    end
  end

  unless maxmemory_policy.empty?
    describe command("#{auth} valkey-cli config get maxmemory-policy") do
      its('stdout') { should match(/^#{Regexp.escape(maxmemory_policy)}$/) }
    end
  end

  unless bind.empty?
    describe command("#{auth} valkey-cli config get bind") do
      its('stdout') { should match(/^#{Regexp.escape(bind)}$/) }
    end
  end

  # Anything passed through the open-ended config property.
  extra_config.split(',').reject(&:empty?).each do |pair|
    directive, expected = pair.split('=', 2)
    describe command("#{auth} valkey-cli config get #{directive}") do
      its('stdout') { should match(/^#{Regexp.escape(expected)}$/) }
    end
  end
end
