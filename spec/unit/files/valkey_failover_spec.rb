require_relative '../../spec_helper'

describe 'valkey-failover' do
  let(:old_master) { { 'ip' => '10.0.0.1', 'port' => '6379' } }
  let(:new_master) { { 'ip' => '10.0.0.2', 'port' => '6379' } }
  let(:primary_info) { { 'role' => 'master', 'connected_slaves' => '2' } }
  let(:demoted_info) { { 'role' => 'slave', 'master_link_status' => 'up' } }
  let(:ckquorum) { ['OK 3 usable Sentinels. Quorum and failover authorization can be reached', true] }
  let(:failover_reply) { ['OK', true] }
  let(:wait_reply) { ['2', true] }
  # Sentinel reports the new primary on the first poll after the switch.
  let(:master_details_replies) { [old_master, new_master] }
  # The old primary answers as primary during preflight, then demoted.
  let(:info_replies) { [primary_info, demoted_info] }

  before do
    # Both wait loops sleep between polls; the script runs at top level,
    # so stubbing sleep on the main object keeps the specs instant.
    allow(TOPLEVEL_BINDING.receiver).to receive(:sleep)
    # The scripts refuse to run without the server config; the context
    # below covers what happens when it really is unreadable.
    allow(ValkeyTools).to receive(:config_readable?).and_return(true)
    allow(ValkeyTools).to receive(:resolve_service).and_return('oslocks')
    allow(ValkeyTools).to receive(:auth_pass).and_return('hunter2')
    allow(ValkeyTools).to receive(:master_details).and_return(*master_details_replies)
    allow(ValkeyTools).to receive(:info_replication).and_return(*info_replies)
    allow(ValkeyTools).to receive(:cli).and_return(wait_reply)
    allow(ValkeyTools).to receive(:sentinel) do |args, **_opts|
      args.first == 'failover' ? failover_reply : ckquorum
    end
  end

  # The failover was actually asked for (or deliberately not).
  def failover_requested?
    expect(ValkeyTools).to have_received(:sentinel).with(%w(failover oslocks), port: 26379)
  end

  def failover_not_requested?
    expect(ValkeyTools).to_not have_received(:sentinel).with(%w(failover oslocks), port: 26379)
  end

  context 'healthy service, confirmation skipped' do
    let(:result) { run_script('valkey-failover', '--yes') }

    it { expect(result.status).to eq 0 }

    it 'reports the starting state, the switch and the demotion' do
      expect(result.stdout).to match(/^Service:      oslocks$/)
      expect(result.stdout).to match(/^Primary:      10\.0\.0\.1:6379$/)
      expect(result.stdout).to match(/^Replicas:     2 connected, all acknowledged$/)
      expect(result.stdout).to match(/^New primary:  10\.0\.0\.2:6379 \(switched in \d+\.\ds\)$/)
      expect(result.stdout).to match(/^Old primary:  demoted to replica, link up$/)
    end

    it 'asks sentinel to fail the service over' do
      result
      failover_requested?
    end

    it 'checks every replica acknowledged writes before switching' do
      result
      expect(ValkeyTools).to have_received(:cli)
        .with(['wait', 2, 5000], host: '10.0.0.1', port: '6379', pass: 'hunter2')
    end

    it 'does not prompt' do
      expect(result.stdout).to_not match(/Confirm with yes/)
    end
  end

  describe 'preflight' do
    context 'quorum unreachable' do
      let(:ckquorum) { ['NOQUORUM 1 usable Sentinels', false] }

      it 'refuses without touching the service' do
        result = run_script('valkey-failover', '--yes')
        expect(result.stderr).to match(/no failover authorization: NOQUORUM/)
        expect(result.status).to eq 1
        failover_not_requested?
      end
    end

    context 'current primary unreachable' do
      let(:info_replies) { [nil] }

      it 'refuses without touching the service' do
        result = run_script('valkey-failover', '--yes')
        expect(result.stderr).to match(/cannot reach the current primary 10\.0\.0\.1:6379/)
        expect(result.status).to eq 1
        failover_not_requested?
      end
    end

    context 'primary has no connected replicas' do
      let(:primary_info) { { 'role' => 'master', 'connected_slaves' => '0' } }

      it 'refuses, since there is nothing to fail over to' do
        result = run_script('valkey-failover', '--yes')
        expect(result.stderr).to match(/no connected replicas to fail over to/)
        expect(result.status).to eq 1
        failover_not_requested?
      end
    end

    context 'a replica is lagging' do
      let(:wait_reply) { ['1', true] }

      it 'refuses rather than risk losing the unacknowledged writes' do
        result = run_script('valkey-failover', '--yes')
        expect(result.stderr).to match(%r{only 1/2 replicas acknowledged all writes})
        expect(result.status).to eq 1
        failover_not_requested?
      end
    end

    context 'the WAIT command itself fails' do
      let(:wait_reply) { ['', false] }

      it 'refuses' do
        result = run_script('valkey-failover', '--yes')
        expect(result.stderr).to match(%r{only 0/2 replicas acknowledged})
        expect(result.status).to eq 1
        failover_not_requested?
      end
    end
  end

  describe 'confirmation prompt' do
    before { allow($stdin).to receive(:gets).and_return(answer) }

    context 'answered yes' do
      let(:answer) { "yes\n" }

      it 'prompts, then proceeds' do
        result = run_script('valkey-failover')
        expect(result.stdout).to match(/Proceed with failover\? Confirm with yes: /)
        expect(result.status).to eq 0
        failover_requested?
      end
    end

    context 'answered YES' do
      let(:answer) { "YES\n" }

      it { expect(run_script('valkey-failover').status).to eq 0 }
    end

    context 'answered no' do
      let(:answer) { "no\n" }

      it 'cancels without touching the service' do
        result = run_script('valkey-failover')
        expect(result.stderr).to match(/Canceled\./)
        expect(result.status).to eq 1
        failover_not_requested?
      end
    end

    context 'input closed (ctrl-d or a pipe)' do
      let(:answer) { nil }

      it 'cancels rather than treating EOF as consent' do
        result = run_script('valkey-failover')
        expect(result.stderr).to match(/Canceled\./)
        expect(result.status).to eq 1
        failover_not_requested?
      end
    end
  end

  context 'sentinel refuses the failover' do
    let(:failover_reply) { ['NOGOODSLAVE No suitable replica to promote', false] }

    it 'stops and reports why' do
      result = run_script('valkey-failover', '--yes')
      expect(result.stderr).to match(/sentinel refused the failover: NOGOODSLAVE/)
      expect(result.status).to eq 1
    end
  end

  context 'the primary never changes' do
    let(:master_details_replies) { [old_master] }

    it 'gives up after the timeout instead of waiting forever' do
      result = run_script('valkey-failover', '--yes', '--timeout', '0')
      expect(result.stderr).to match(/primary did not change within 0s/)
      expect(result.status).to eq 1
    end
  end

  context 'the old primary is demoted but still syncing' do
    let(:info_replies) { [primary_info, demoted_info.merge('master_link_status' => 'down')] }

    it 'waits for the link rather than reporting a replacement that is not ready' do
      result = run_script('valkey-failover', '--yes', '--timeout', '1')
      expect(result.stdout).to match(/^Old primary:  demoted to replica, but its link is still down/)
      expect(result.stdout).to_not match(/link up/)
      expect(result.status).to eq 2
    end
  end

  context 'the old primary goes unreachable during the switch' do
    let(:info_replies) { [primary_info, nil] }

    # The preflight proved this node was up, so losing it mid-switch is
    # an anomaly, and the cluster is left a replica short either way.
    it 'reports it rather than exiting clean' do
      result = run_script('valkey-failover', '--yes', '--timeout', '1')
      expect(result.stdout).to match(/^Old primary:  went unreachable during the failover/)
      expect(result.stdout).to_not match(/link up/)
      expect(result.status).to eq 2
    end
  end

  context 'the old primary never demotes' do
    it 'warns and exits non-zero so maintenance is not ended blindly' do
      result = run_script('valkey-failover', '--yes', '--timeout', '0')
      expect(result.stdout).to match(/^Old primary:  still reports role:master; check it/)
      expect(result.status).to eq 2
    end
  end

  it 'passes an explicit service and sentinel port through' do
    run_script('valkey-failover', '--yes', '--service', 'other', '--sentinel-port', '36379')
    expect(ValkeyTools).to have_received(:resolve_service).with('other', port: 36379)
    expect(ValkeyTools).to have_received(:sentinel).with(%w(failover oslocks), port: 36379)
  end

  context 'run without access to the server config' do
    before { allow(ValkeyTools).to receive(:config_readable?).and_return(false) }

    it 'refuses before touching the service' do
      result = run_script('valkey-failover', '--yes')
      expect(result.stderr).to match(%r{cannot read /etc/valkey/valkey\.conf})
      expect(result.status).to eq 1
      failover_not_requested?
    end
  end

  it 'prints usage for --help without touching the service' do
    result = run_script('valkey-failover', '--help')
    expect(result.stdout).to match(/Usage: valkey-failover/)
    expect(result.status).to eq 0
    expect(ValkeyTools).to_not have_received(:master_details)
  end
end
