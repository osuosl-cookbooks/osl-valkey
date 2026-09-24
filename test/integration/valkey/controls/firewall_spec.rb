# The ports osl_firewall_port opened. Skipped where iptables is not
# available (dokken) or where a wrapper turned the firewall property
# off.
firewall = input('firewall', value: true)
port = input('valkey_port', value: 6379).to_s
sentinel = input('sentinel', value: false)
sentinel_port = input('sentinel_port', value: 26379).to_s
# 'name:port' pairs for instances that open their own chain
instance_ports = input('instance_firewall', value: '').to_s

control 'firewall' do
  only_if('firewall management is disabled for this suite') { firewall }

  describe iptables do
    it { should have_rule('-N valkey') }
    it { should have_rule("-A valkey -p tcp -m tcp --dport #{port} -j osl_only") }
  end

  instance_ports.split(',').reject(&:empty?).each do |pair|
    name, instance_port = pair.split(':', 2)
    describe iptables do
      it { should have_rule("-N valkey-#{name}") }
      it { should have_rule("-A valkey-#{name} -p tcp -m tcp --dport #{instance_port} -j osl_only") }
    end
  end

  if sentinel
    describe iptables do
      it { should have_rule('-N valkey_sentinel') }
      it { should have_rule("-A valkey_sentinel -p tcp -m tcp --dport #{sentinel_port} -j osl_only") }
    end
  else
    describe iptables do
      it { should_not have_rule('-N valkey_sentinel') }
    end
  end
end
