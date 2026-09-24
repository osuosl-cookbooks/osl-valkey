# valkey@<name> units, each with its own process, port, config, data dir and log.
# Inputs stay scalar: 'name:port,...' and 'name:directive=value,...'.
instances = input('instances', value: '').to_s.split(',').to_h { |pair| pair.split(':', 2) }
instance_config = input('instance_config', value: '').to_s
pass = input('instance_pass', value: '').to_s
pass_names = input('instance_pass_names', value: '').to_s.split(',')

cli = lambda do |name|
  auth = pass_names.include?(name) ? "REDISCLI_AUTH='#{pass}' " : ''
  "#{auth}valkey-cli -p #{instances[name]}"
end

control 'instances' do
  describe file('/etc/systemd/system/valkey@.service') do
    its('content') { should match(/^Restart=on-failure$/) }
    its('content') { should match(/^RuntimeDirectory=valkey-%i$/) }
  end

  instances.each do |name, port|
    describe service("valkey@#{name}") do
      it { should be_enabled }
      it { should be_running }
    end

    describe command("systemctl show -p Restart valkey@#{name}.service") do
      its('stdout') { should match(/^Restart=on-failure$/) }
    end

    describe port(port.to_i) do
      it { should be_listening }
    end

    describe command("semanage port -l | grep '^redis_port_t'") do
      its('stdout') { should match(/\b#{port}\b/) }
    end

    describe file("/etc/valkey/.#{name}.conf.chef") do
      its('content') { should match(/^1$/) }
    end

    describe file("/var/lib/valkey/#{name}") do
      it { should be_directory }
      it { should be_owned_by 'valkey' }
    end

    {
      'port' => port,
      'dir' => "/var/lib/valkey/#{name}",
      'logfile' => "/var/log/valkey/#{name}.log",
    }.each do |directive, expected|
      describe command("#{cli.call(name)} config get #{directive}") do
        its('stdout') { should match(/^#{Regexp.escape(expected)}$/) }
      end
    end
  end

  instance_config.split(',').reject(&:empty?).each do |setting|
    name, pair = setting.split(':', 2)
    directive, expected = pair.split('=', 2)
    describe command("#{cli.call(name)} config get #{directive}") do
      its('stdout') { should eq "#{directive}\n#{expected}\n" }
    end
  end
end
