require 'stringio'
require_relative '../../spec_helper'
require_relative '../../../files/valkey_tools'

describe ValkeyTools do
  # abort() writes to stderr before raising SystemExit; keep the spec
  # output readable.
  around do |example|
    original = $stderr
    $stderr = StringIO.new
    example.run
    $stderr = original
  end

  # A finished valkey-cli run. Errors reach us on either stream, so the
  # helper takes both.
  def shellout(stdout: '', stderr: '', exitstatus: 0)
    instance_double(
      Mixlib::ShellOut,
      run_command: nil,
      stdout: stdout,
      stderr: stderr,
      exitstatus: exitstatus
    )
  end

  # Command line valkey-cli was actually invoked with, options aside.
  def invoked_argv
    args = nil
    allow(Mixlib::ShellOut).to receive(:new) do |*passed|
      args = passed
      shellout(stdout: "PONG\n")
    end
    yield
    args.reject { |a| a.is_a?(Hash) }
  end

  describe '.auth_pass' do
    let(:conf) { '/etc/valkey/valkey.conf' }
    let(:readable) { true }
    let(:lines) { ["port 6379\n", "requirepass hunter2\n", "appendonly yes\n"] }

    before do
      allow(File).to receive(:readable?).and_call_original
      allow(File).to receive(:readlines).and_call_original
      allow(File).to receive(:readable?).with(conf).and_return(readable)
      allow(File).to receive(:readlines).with(conf).and_return(lines)
    end

    it { expect(ValkeyTools.auth_pass).to eq 'hunter2' }

    context 'config unreadable (not running as root)' do
      let(:readable) { false }

      it { expect(ValkeyTools.auth_pass).to be_nil }
      it 'does not try to read it' do
        ValkeyTools.auth_pass
        expect(File).to_not have_received(:readlines).with(conf)
      end
    end

    context 'value quoted by CONFIG REWRITE' do
      let(:lines) { ["requirepass \"hunter2\"\n"] }

      it { expect(ValkeyTools.auth_pass).to eq 'hunter2' }
    end

    context 'quoted value containing spaces' do
      let(:lines) { ["requirepass \"two words\"\n"] }

      it { expect(ValkeyTools.auth_pass).to eq 'two words' }
    end

    context 'no auth configured' do
      let(:lines) { ["port 6379\n", "# requirepass commented-out\n"] }

      it { expect(ValkeyTools.auth_pass).to be_nil }
    end
  end

  describe '.cli' do
    before { allow(Mixlib::ShellOut).to receive(:new).and_return(shellout(stdout: "PONG\n")) }

    it 'returns the trimmed output and a success flag' do
      expect(ValkeyTools.cli(%w(ping))).to eq ['PONG', true]
    end

    # Connection failures arrive on stderr, so reading stdout alone
    # would report an empty reply for an unreachable member.
    it 'reports a failed command without raising' do
      allow(Mixlib::ShellOut).to receive(:new)
        .and_return(shellout(stderr: "Could not connect\n", exitstatus: 1))
      expect(ValkeyTools.cli(%w(ping))).to eq ['Could not connect', false]
    end

    # valkey-cli prints server errors and still exits 0, so trusting the
    # exit status alone would report NOQUORUM as a success and silently
    # disarm every check built on this.
    [
      'NOQUORUM 1 usable Sentinels. Not enough available Sentinels to reach the specified quorum',
      'ERR No such master with that name',
      'NOAUTH Authentication required.',
      'NOGOODSLAVE No suitable replica to promote',
      '(error) ERR unknown command',
    ].each do |reply|
      it "treats #{reply.split.first} as a failure even when the process exits 0" do
        allow(Mixlib::ShellOut).to receive(:new).and_return(shellout(stdout: "#{reply}\n"))
        expect(ValkeyTools.cli(%w(sentinel ckquorum svc))).to eq [reply, false]
      end
    end

    it 'does not mistake an ordinary reply for an error' do
      allow(Mixlib::ShellOut).to receive(:new).and_return(shellout(stdout: "ERROR_LOG_LINE\n"))
      expect(ValkeyTools.cli(%w(get somekey))).to eq ['ERROR_LOG_LINE', true]
    end

    # A wedged member must not hang an operator's status check.
    it 'gives up rather than waiting on a command that never returns' do
      timed_out = shellout
      allow(timed_out).to receive(:run_command).and_raise(Mixlib::ShellOut::CommandTimeout)
      allow(Mixlib::ShellOut).to receive(:new).and_return(timed_out)

      reply, ok = ValkeyTools.cli(%w(ping), host: 'wedged.example.org')
      expect(reply).to match(/did not return within \d+s/)
      expect(ok).to be(false)
    end

    it 'bounds every call with a timeout' do
      ValkeyTools.cli(%w(ping))
      expect(Mixlib::ShellOut).to have_received(:new)
        .with(any_args, hash_including(timeout: ValkeyTools::TIMEOUT))
    end

    it 'talks to the local server by default' do
      expect(invoked_argv { ValkeyTools.cli(%w(ping)) })
        .to eq %w(/usr/bin/valkey-cli ping)
    end

    it 'targets an explicit host and port' do
      expect(invoked_argv { ValkeyTools.cli(%w(ping), host: 'mq2.example.org', port: 6379) })
        .to eq %w(/usr/bin/valkey-cli -h mq2.example.org -p 6379 ping)
    end

    it 'targets a port on the local host' do
      expect(invoked_argv { ValkeyTools.cli(%w(sentinel masters), port: 26379) })
        .to eq %w(/usr/bin/valkey-cli -p 26379 sentinel masters)
    end

    it 'stringifies non-string arguments' do
      expect(invoked_argv { ValkeyTools.cli(['wait', 2, 5000]) })
        .to eq %w(/usr/bin/valkey-cli wait 2 5000)
    end

    it 'passes the password by environment, never on the command line' do
      captured = nil
      allow(Mixlib::ShellOut).to receive(:new) do |*args|
        captured = args
        shellout(stdout: "PONG\n")
      end

      ValkeyTools.cli(%w(ping), pass: 'hunter2')

      argv = captured.reject { |a| a.is_a?(Hash) }
      options = captured.find { |a| a.is_a?(Hash) }
      expect(options[:env]).to eq('REDISCLI_AUTH' => 'hunter2')
      expect(argv).to include('--no-auth-warning')
      expect(argv).to_not include('hunter2')
    end
  end

  describe '.sentinel' do
    before { allow(ValkeyTools).to receive(:cli).and_return(['OK', true]) }

    it 'prefixes the subcommand and defaults to the sentinel port' do
      ValkeyTools.sentinel(%w(ckquorum oslocks))
      expect(ValkeyTools).to have_received(:cli).with(%w(sentinel ckquorum oslocks), port: 26379)
    end

    it 'honors an explicit port' do
      ValkeyTools.sentinel(%w(masters), port: 36379)
      expect(ValkeyTools).to have_received(:cli).with(%w(sentinel masters), port: 36379)
    end
  end

  describe '.pairs' do
    it 'reads alternating name/value lines as a hash' do
      expect(ValkeyTools.pairs("ip\n10.0.0.1\nport\n6379")).to eq(
        'ip' => '10.0.0.1',
        'port' => '6379'
      )
    end

    it { expect(ValkeyTools.pairs('')).to eq({}) }

    # A non-map reply is not something to raise ArgumentError over in
    # front of an operator.
    it 'survives a reply that is not a map' do
      expect { ValkeyTools.pairs('ERR No such master with that name') }.to_not raise_error
    end
  end

  describe '.config_readable?' do
    it 'is true when the server config can be read' do
      allow(File).to receive(:readable?).and_call_original
      allow(File).to receive(:readable?).with('/etc/valkey/valkey.conf').and_return(true)
      expect(ValkeyTools.config_readable?).to be(true)
    end

    it 'is false when it cannot, which is not the same as no password being set' do
      allow(File).to receive(:readable?).and_call_original
      allow(File).to receive(:readable?).with('/etc/valkey/valkey.conf').and_return(false)
      expect(ValkeyTools.config_readable?).to be(false)
      expect(ValkeyTools.auth_pass).to be_nil
    end
  end

  describe '.info_replication' do
    # valkey-cli relays the INFO payload with its protocol CRLFs.
    let(:reply) do
      [
        '# Replication',
        'role:master',
        'connected_slaves:2',
        'slave0:ip=10.0.0.2,port=6379,state=online,offset=112,lag=0',
        'master_failover_state:no-failover',
        'master_repl_offset:112',
      ].join("\r\n")
    end

    before { allow(ValkeyTools).to receive(:cli).and_return([reply, true]) }

    it 'asks the given member with its password' do
      ValkeyTools.info_replication('10.0.0.1', 6379, 'hunter2')
      expect(ValkeyTools).to have_received(:cli)
        .with(%w(info replication), host: '10.0.0.1', port: 6379, pass: 'hunter2')
    end

    it 'parses the fields, dropping section headers and carriage returns' do
      expect(ValkeyTools.info_replication('10.0.0.1', 6379, 'hunter2')).to eq(
        'role' => 'master',
        'connected_slaves' => '2',
        'slave0' => 'ip=10.0.0.2,port=6379,state=online,offset=112,lag=0',
        'master_failover_state' => 'no-failover',
        'master_repl_offset' => '112'
      )
    end

    context 'replica member' do
      let(:reply) do
        ['# Replication', 'role:slave', 'master_host:10.0.0.1', 'master_link_status:up'].join("\r\n")
      end

      it do
        expect(ValkeyTools.info_replication('10.0.0.2', 6379, 'hunter2')).to eq(
          'role' => 'slave',
          'master_host' => '10.0.0.1',
          'master_link_status' => 'up'
        )
      end
    end

    context 'section header containing a colon' do
      let(:reply) { ['# Replication: notes', 'role:master'].join("\r\n") }

      it 'drops the comment line rather than reading it as a field' do
        expect(ValkeyTools.info_replication('10.0.0.1', 6379, nil)).to eq('role' => 'master')
      end
    end

    context 'member unreachable' do
      before { allow(ValkeyTools).to receive(:cli).and_return(['Could not connect', false]) }

      it { expect(ValkeyTools.info_replication('10.0.0.9', 6379, 'hunter2')).to be_nil }
    end

    context 'reply without a role (an error string)' do
      before { allow(ValkeyTools).to receive(:cli).and_return(['NOAUTH Authentication required.', true]) }

      it { expect(ValkeyTools.info_replication('10.0.0.1', 6379, nil)).to be_nil }
    end
  end

  describe '.sentinel_services' do
    let(:reply) do
      <<~REPLY.strip
        name
        oslocks
        ip
        10.0.0.1
        port
        6379
        flags
        master
        num-slaves
        2
      REPLY
    end

    before { allow(ValkeyTools).to receive(:sentinel).and_return([reply, true]) }

    it 'lists the monitored service names' do
      expect(ValkeyTools.sentinel_services).to eq %w(oslocks)
      expect(ValkeyTools).to have_received(:sentinel).with(%w(masters), port: 26379)
    end

    context 'several services monitored' do
      let(:reply) do
        <<~REPLY.strip
          name
          oslocks
          ip
          10.0.0.1
          name
          sessions
          ip
          10.0.0.1
        REPLY
      end

      it { expect(ValkeyTools.sentinel_services).to eq %w(oslocks sessions) }
    end

    context 'sentinel monitoring nothing' do
      before { allow(ValkeyTools).to receive(:sentinel).and_return(['', true]) }

      it { expect(ValkeyTools.sentinel_services).to eq [] }
    end

    context 'sentinel unreachable' do
      before { allow(ValkeyTools).to receive(:sentinel).and_return(['Could not connect', false]) }

      it { expect(ValkeyTools.sentinel_services).to eq [] }
    end
  end

  describe '.resolve_service' do
    before { allow(ValkeyTools).to receive(:sentinel_services).and_return(%w(oslocks)) }

    it 'takes an explicit name without asking sentinel' do
      expect(ValkeyTools.resolve_service('other')).to eq 'other'
      expect(ValkeyTools).to_not have_received(:sentinel_services)
    end

    it 'falls back to the only monitored service' do
      expect(ValkeyTools.resolve_service(nil)).to eq 'oslocks'
    end

    it 'passes an explicit sentinel port through' do
      ValkeyTools.resolve_service(nil, port: 36379)
      expect(ValkeyTools).to have_received(:sentinel_services).with(port: 36379)
    end

    context 'nothing monitored' do
      before { allow(ValkeyTools).to receive(:sentinel_services).and_return([]) }

      it { expect { ValkeyTools.resolve_service(nil) }.to raise_error(SystemExit, /monitors no services/) }
    end

    context 'several monitored' do
      before { allow(ValkeyTools).to receive(:sentinel_services).and_return(%w(oslocks sessions)) }

      it 'aborts naming the candidates' do
        expect { ValkeyTools.resolve_service(nil) }
          .to raise_error(SystemExit, /several services \(oslocks, sessions\); pick one with --service/)
      end
    end
  end

  describe '.master_details' do
    # Through the real cli, not a stubbed verdict: sentinel answers an
    # unknown service with text containing the word 'name', so the
    # content check alone passes it through and pairs then chokes. The
    # guard has to come from cli's error detection.
    context 'unknown service, exercised end to end' do
      before do
        allow(ValkeyTools).to receive(:sentinel).and_call_original
        allow(Mixlib::ShellOut).to receive(:new).and_return(shellout(stdout: "ERR No such master with that name\n"))
      end

      it 'aborts with the intended message rather than raising' do
        expect { ValkeyTools.master_details('nope') }
          .to raise_error(SystemExit, /does not know service 'nope'/)
      end
    end

    let(:reply) do
      <<~REPLY.strip
        name
        oslocks
        ip
        10.0.0.1
        port
        6379
        flags
        master
        num-slaves
        2
        num-other-sentinels
        2
        quorum
        2
      REPLY
    end

    before { allow(ValkeyTools).to receive(:sentinel).and_return([reply, true]) }

    it 'returns the primary address and quorum state' do
      details = ValkeyTools.master_details('oslocks')
      expect(details).to include(
        'ip' => '10.0.0.1',
        'port' => '6379',
        'flags' => 'master',
        'num-slaves' => '2',
        'num-other-sentinels' => '2',
        'quorum' => '2'
      )
      expect(ValkeyTools).to have_received(:sentinel).with(%w(master oslocks), port: 26379)
    end

    context 'service unknown to sentinel' do
      before { allow(ValkeyTools).to receive(:sentinel).and_return(['ERR No such master with that name', false]) }

      it do
        expect { ValkeyTools.master_details('nope') }
          .to raise_error(SystemExit, /does not know service 'nope'/)
      end
    end

    context 'sentinel unreachable' do
      before { allow(ValkeyTools).to receive(:sentinel).and_return(['Could not connect', false]) }

      it { expect { ValkeyTools.master_details('oslocks') }.to raise_error(SystemExit) }
    end
  end

  describe '.replica_details' do
    let(:reply) do
      <<~REPLY.strip
        name
        10.0.0.2:6379
        ip
        10.0.0.2
        port
        6379
        flags
        slave
        master-link-status
        ok
        name
        10.0.0.3:6379
        ip
        10.0.0.3
        port
        6379
        flags
        slave
        master-link-status
        ok
      REPLY
    end

    before { allow(ValkeyTools).to receive(:sentinel).and_return([reply, true]) }

    it 'splits the flat reply into one hash per replica' do
      replicas = ValkeyTools.replica_details('oslocks')
      expect(replicas.length).to eq 2
      expect(replicas.map { |r| r['ip'] }).to eq %w(10.0.0.2 10.0.0.3)
      expect(replicas.first).to include('port' => '6379', 'master-link-status' => 'ok')
      expect(ValkeyTools).to have_received(:sentinel).with(%w(replicas oslocks), port: 26379)
    end

    context 'no replicas yet' do
      before { allow(ValkeyTools).to receive(:sentinel).and_return(['', true]) }

      it { expect(ValkeyTools.replica_details('oslocks')).to eq [] }
    end

    context 'sentinel unreachable' do
      before { allow(ValkeyTools).to receive(:sentinel).and_return(['Could not connect', false]) }

      it { expect(ValkeyTools.replica_details('oslocks')).to eq [] }
    end
  end
end
