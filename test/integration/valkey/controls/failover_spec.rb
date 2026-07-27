# Multi-node only, and runs last: an orchestrated failover through the
# cookbook's own tool, proving the cluster survives losing its primary
# on purpose. Everything is relative to whichever member is primary
# when it starts, so re-verifying an already failed-over cluster works
# - it simply moves the primary again.
pass = input('valkey_pass', value: '').to_s
service = input('service_name', value: 'testlocks').to_s
sentinel_port = input('sentinel_port', value: 26379).to_s
monitor_port = input('valkey_port', value: 6379).to_s
members = input('members', value: '10.1.0.11,10.1.0.12,10.1.0.13').to_s.split(',')
replica_count = input('sentinel_replicas', value: 2).to_i
sentinel_count = input('sentinel_count', value: 3).to_i
auth = pass.empty? ? '' : "REDISCLI_AUTH='#{pass}'"

control 'failover' do
  # Captured before the failover runs: control bodies are evaluated
  # ahead of the examples they register.
  old_primary = command("valkey-cli -p #{sentinel_port} sentinel get-master-addr-by-name #{service}")
                .stdout.lines.first.to_s.strip
  failover = command('/usr/local/bin/valkey-failover --yes')

  describe failover do
    its('exit_status') { should eq 0 }
    # Preflight saw every replica caught up before switching anything.
    its('stdout') { should match(/^Replicas:     #{replica_count} connected, all acknowledged$/) }
    its('stdout') { should match(/^New primary:  \S+:#{monitor_port} \(switched in \d+\.\ds\)$/) }
    its('stdout') { should match(/^Old primary:  demoted to replica, link up$/) }
  end

  # Sentinel promoted a different member.
  describe command("valkey-cli -p #{sentinel_port} sentinel get-master-addr-by-name #{service}") do
    its('stdout') { should_not match(/^#{Regexp.escape(old_primary)}$/) }
    its('stdout') { should match(/^(#{members.map { |ip| Regexp.escape(ip) }.join('|')})$/) }
  end

  # The member that was primary rejoined as a replica of the new one.
  describe command("#{auth} valkey-cli -h #{old_primary} info replication") do
    its('stdout') { should match(/^role:slave/) }
    its('stdout') { should match(/^master_link_status:up/) }
  end

  # The cluster is still healthy afterwards and the write made before
  # the switch survived it (read from this node, whatever its role).
  describe command("valkey-cli -p #{sentinel_port} sentinel ckquorum #{service}") do
    its('exit_status') { should eq 0 }
    its('stdout') { should match(/^OK #{sentinel_count} usable Sentinels/) }
  end
  describe command("#{auth} valkey-cli get inspec-probe") do
    its('stdout') { should match(/^hello$/) }
  end
  describe command('/usr/local/bin/valkey-status') do
    its('exit_status') { should eq 0 }
    its('stdout') { should_not match(/DOWN or unreachable/) }
  end
end
