require_relative '../../spec_helper'

describe 'valkey-status' do
  # A healthy 3-member service, as sentinel and the members report it.
  let(:master) do
    {
      'name' => 'oslocks',
      'ip' => '10.0.0.1',
      'port' => '6379',
      'flags' => 'master',
      'num-slaves' => '2',
      'num-other-sentinels' => '2',
      'quorum' => '2',
    }
  end
  let(:replicas) do
    [
      { 'ip' => '10.0.0.2', 'port' => '6379' },
      { 'ip' => '10.0.0.3', 'port' => '6379' },
    ]
  end
  let(:ckquorum) { ['OK 3 usable Sentinels. Quorum and failover authorization can be reached', true] }
  let(:primary_info) do
    { 'role' => 'master', 'connected_slaves' => '2', 'master_repl_offset' => '112' }
  end
  let(:replica_info) do
    {
      'role' => 'slave',
      'master_host' => '10.0.0.1',
      'master_link_status' => 'up',
      'slave_repl_offset' => '112',
    }
  end
  let(:third_member_info) { replica_info }

  before do
    # The scripts refuse to run without the server config; the context
    # below covers what happens when it really is unreadable.
    allow(ValkeyTools).to receive(:config_readable?).and_return(true)
    allow(ValkeyTools).to receive(:resolve_service).and_return('oslocks')
    allow(ValkeyTools).to receive(:master_details).and_return(master)
    allow(ValkeyTools).to receive(:sentinel).and_return(ckquorum)
    allow(ValkeyTools).to receive(:auth_pass).and_return('hunter2')
    allow(ValkeyTools).to receive(:replica_details).and_return(replicas)
    allow(ValkeyTools).to receive(:info_replication).with('10.0.0.1', '6379', 'hunter2').and_return(primary_info)
    allow(ValkeyTools).to receive(:info_replication).with('10.0.0.2', '6379', 'hunter2').and_return(replica_info)
    allow(ValkeyTools).to receive(:info_replication).with('10.0.0.3', '6379', 'hunter2').and_return(third_member_info)
  end

  context 'healthy service' do
    let(:result) { run_script('valkey-status') }

    it { expect(result.status).to eq 0 }

    it 'summarizes what sentinel knows' do
      expect(result.stdout).to match(/^Service:  oslocks$/)
      expect(result.stdout).to match(/^Primary:  10\.0\.0\.1:6379 \(flags: master\)$/)
      expect(result.stdout).to match(/^Quorum:   2 \(3 sentinels known, ckquorum: OK\)$/)
      expect(result.stdout).to match(/^Replicas: 2 known to sentinel$/)
    end

    it 'reports live replication state per member' do
      expect(result.stdout).to match(/^MEMBER\s+ROLE\s+LINK\s+REPLICAS\s+OFFSET$/)
      expect(result.stdout).to match(/^10\.0\.0\.1:6379\s+master\s+-\s+2\s+112$/)
      expect(result.stdout).to match(/^10\.0\.0\.2:6379\s+replica\s+up\s+-\s+112$/)
      expect(result.stdout).to match(/^10\.0\.0\.3:6379\s+replica\s+up\s+-\s+112$/)
    end

    it 'reads the password once and reuses it for every member' do
      result
      expect(ValkeyTools).to have_received(:auth_pass).once
      expect(ValkeyTools).to have_received(:info_replication).exactly(3).times
    end
  end

  context 'a member is down' do
    let(:third_member_info) { nil }

    it 'flags it and exits non-zero' do
      result = run_script('valkey-status')
      expect(result.stdout).to match(/^10\.0\.0\.3:6379\s+DOWN or unreachable$/)
      expect(result.status).to eq 2
    end
  end

  context 'a replica link is broken' do
    let(:third_member_info) { replica_info.merge('master_link_status' => 'down') }

    it 'exits non-zero even though the member answers' do
      result = run_script('valkey-status')
      expect(result.stdout).to match(/^10\.0\.0\.3:6379\s+replica\s+down/)
      expect(result.status).to eq 2
    end
  end

  context 'quorum is not reachable' do
    let(:ckquorum) { ['NOQUORUM 1 usable Sentinels. Not enough available sentinels to reach the majority', false] }

    it 'reports the sentinel error and exits non-zero' do
      result = run_script('valkey-status')
      expect(result.stdout).to match(/ckquorum: FAILED/)
      expect(result.stdout).to match(/^ckquorum: NOQUORUM 1 usable Sentinels/)
      expect(result.status).to eq 2
    end
  end

  context 'no replicas known to sentinel yet' do
    let(:replicas) { [] }

    it 'lists just the primary' do
      result = run_script('valkey-status')
      expect(result.stdout).to match(/^10\.0\.0\.1:6379\s+master/)
      expect(result.stdout).to_not match(/10\.0\.0\.2/)
      expect(result.status).to eq 0
    end
  end

  it 'passes an explicit service and sentinel port through' do
    run_script('valkey-status', '--service', 'other', '--sentinel-port', '36379')
    expect(ValkeyTools).to have_received(:resolve_service).with('other', port: 36379)
    expect(ValkeyTools).to have_received(:master_details).with('oslocks', port: 36379)
    expect(ValkeyTools).to have_received(:sentinel).with(%w(ckquorum oslocks), port: 36379)
  end

  it 'defaults to the standard sentinel port' do
    run_script('valkey-status')
    expect(ValkeyTools).to have_received(:resolve_service).with(nil, port: 26379)
  end

  # Without the config there is no password, and every authenticated
  # member answers NOAUTH - which would read as a total outage.
  context 'run without access to the server config' do
    before { allow(ValkeyTools).to receive(:config_readable?).and_return(false) }

    it 'says so instead of reporting every member down' do
      result = run_script('valkey-status')
      expect(result.stderr).to match(%r{cannot read /etc/valkey/valkey\.conf})
      expect(result.stdout).to_not match(/DOWN or unreachable/)
      expect(result.status).to eq 1
    end
  end

  it 'prints usage for --help without querying anything' do
    result = run_script('valkey-status', '--help')
    expect(result.stdout).to match(/Usage: valkey-status/)
    expect(result.status).to eq 0
    expect(ValkeyTools).to_not have_received(:master_details)
  end
end
