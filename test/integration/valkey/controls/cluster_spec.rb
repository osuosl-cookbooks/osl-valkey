# Multi-node only: the state that only exists once several members are
# talking to each other. Everything true of a lone server or sentinel
# is asserted by the 'server' and 'sentinel' controls instead.
pass = input('valkey_pass', value: '').to_s
service = input('service_name', value: 'testlocks').to_s
sentinel_port = input('sentinel_port', value: 26379).to_s
members = input('members', value: '10.1.0.11,10.1.0.12,10.1.0.13').to_s.split(',')
replica_count = input('sentinel_replicas', value: 2).to_i
auth = pass.empty? ? '' : "REDISCLI_AUTH='#{pass}'"

control 'cluster' do
  # Every member answers over the private cluster network, which is
  # what replication and sentinel gossip run over. Probing with
  # valkey-cli also proves the shared password works between members
  # and needs no extra tooling on the image.
  members.each do |ip|
    describe command("#{auth} valkey-cli -h #{ip} ping") do
      its('stdout') { should match(/^PONG$/) }
    end
  end

  # Whoever sentinel currently calls primary is one of the members.
  describe command("valkey-cli -p #{sentinel_port} sentinel get-master-addr-by-name #{service}") do
    its('exit_status') { should eq 0 }
    its('stdout') { should match(/^(#{members.map { |ip| Regexp.escape(ip) }.join('|')})$/) }
  end

  # This member's own role is coherent: a primary carries every
  # replica, a replica has its link up. Stated as an either/or so it
  # holds whichever node is primary at the time.
  describe command("#{auth} valkey-cli info replication") do
    its('stdout') { should match(/^role:(master|slave)/) }
    its('stdout') { should match(/^(connected_slaves:#{replica_count}|master_link_status:up)/) }
  end
end
