# The ports osl_firewall_port opened. Skipped where iptables is not
# available (dokken) or where a wrapper turned the firewall property
# off.
firewall = input('firewall', value: true)
port = input('valkey_port', value: 6379).to_s
sentinel = input('sentinel', value: false)
sentinel_port = input('sentinel_port', value: 26379).to_s

control 'firewall' do
  only_if('firewall management is disabled for this suite') { firewall }

  describe iptables do
    it { should have_rule('-N valkey') }
    it { should have_rule("-A valkey -p tcp -m tcp --dport #{port} -j osl_only") }
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
