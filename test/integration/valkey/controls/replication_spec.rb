# Multi-node only, and cluster-wide, so it runs on one system rather
# than each of them. Every assertion is relative to whichever member
# sentinel currently calls primary: chef seeds valkey1, but a failover
# moves it, and this has to keep passing either way so the suite can be
# re-verified without rebuilding the cluster. That chef seeds the right
# member is covered by the cluster recipe's unit specs.
pass = input('valkey_pass', value: '').to_s
service = input('service_name', value: 'testlocks').to_s
sentinel_port = input('sentinel_port', value: 26379).to_s
members = input('members', value: '10.1.0.11,10.1.0.12,10.1.0.13').to_s.split(',')
replica_count = input('sentinel_replicas', value: 2).to_i
auth = pass.empty? ? '' : "REDISCLI_AUTH='#{pass}'"

control 'replication' do
  primary = command("valkey-cli -p #{sentinel_port} sentinel get-master-addr-by-name #{service}")
            .stdout.lines.first.to_s.strip
  replicas = members - [primary]

  describe 'the address sentinel serves to clients' do
    it 'is one of the cluster members' do
      expect(members).to include(primary)
    end
  end

  # The primary carries every replica, and names them as online.
  describe command("#{auth} valkey-cli -h #{primary} info replication") do
    its('stdout') { should match(/^role:master/) }
    its('stdout') { should match(/^connected_slaves:#{replica_count}/) }
  end
  replicas.each do |ip|
    describe command("#{auth} valkey-cli -h #{primary} info replication") do
      its('stdout') { should match(/^slave\d+:ip=#{Regexp.escape(ip)},port=\d+,state=online/) }
    end
  end

  replicas.each do |ip|
    describe command("#{auth} valkey-cli -h #{ip} info replication") do
      its('stdout') { should match(/^role:slave/) }
      its('stdout') { should match(/^master_host:#{Regexp.escape(primary)}/) }
      its('stdout') { should match(/^master_link_status:up/) }
    end

    # A replica refuses writes, so a client that reaches the wrong
    # member cannot diverge from the primary.
    describe command("#{auth} valkey-cli -h #{ip} set inspec-replica-write nope") do
      its('stdout') { should match(/READONLY/) }
    end
  end

  # A write to the primary is acknowledged by every replica (WAIT) and
  # then served by each of them. This key is also what the failover
  # control checks survived the switch.
  describe command("#{auth} valkey-cli -h #{primary} set inspec-probe hello") do
    its('stdout') { should match(/^OK$/) }
  end
  describe command("#{auth} valkey-cli -h #{primary} wait #{replica_count} 5000") do
    its('stdout') { should match(/^#{replica_count}$/) }
  end
  replicas.each do |ip|
    describe command("#{auth} valkey-cli -h #{ip} get inspec-probe") do
      its('stdout') { should match(/^hello$/) }
    end
  end
end
