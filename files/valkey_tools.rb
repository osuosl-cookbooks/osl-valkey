# Shared helpers for the valkey operator scripts (valkey-status,
# valkey-failover), ported from the ha-valkey ansible role's
# common_redis.py. Talks to valkey/sentinel by shelling out to
# valkey-cli; the password travels via REDISCLI_AUTH, never argv.
# mixlib-shellout rather than open3: it ships in the same omnibus as the
# ruby in the shebang, and it can bound a call that never returns.
require 'mixlib/shellout'

module ValkeyTools
  VALKEY_CLI = '/usr/bin/valkey-cli'.freeze
  VALKEY_CONF = '/etc/valkey/valkey.conf'.freeze
  SENTINEL_PORT = 26379

  # Long enough for a slow but working member, short enough that one
  # wedged member cannot hang a status check or a failover indefinitely.
  TIMEOUT = 10

  module_function

  # Error replies valkey answers with. valkey-cli prints these on stdout
  # and still exits 0, so a check that trusts the exit status alone
  # reads 'NOQUORUM ...' as a success and silently disarms itself.
  ERROR_REPLY = /\A(?:\(error\)\s*)?(?:ERR|WRONGPASS|NOAUTH|NOPERM|NOQUORUM|NOGOODSLAVE|NOMASTER|MASTERDOWN|LOADING|BUSY|READONLY|WRONGTYPE|MISCONF)\b/

  # Whether the local server config can be read at all. Distinguishes
  # "no password is configured" from "we are not root", which otherwise
  # look identical and make every authenticated member appear down.
  def config_readable?
    File.readable?(VALKEY_CONF)
  end

  # requirepass from the local server config (root-only); nil when
  # unreadable or unset. CONFIG REWRITE may quote the value.
  def auth_pass
    return unless config_readable?
    line = File.readlines(VALKEY_CONF).find { |l| l.start_with?('requirepass ') }
    line&.split(' ', 2)&.last&.strip&.delete('"')
  end

  # Returns [reply, ok]. ok is false for a transport failure *and* for a
  # server error reply, so callers can treat both as "did not work".
  def cli(args, host: nil, port: nil, pass: nil)
    cmd = [VALKEY_CLI]
    cmd += ['-h', host] if host
    cmd += ['-p', port.to_s] if port
    cmd << '--no-auth-warning' if pass
    cmd += args.map(&:to_s)
    env = pass ? { 'REDISCLI_AUTH' => pass } : {}

    shell = Mixlib::ShellOut.new(*cmd, env: env, timeout: TIMEOUT)
    begin
      shell.run_command
    rescue Mixlib::ShellOut::CommandTimeout
      return ["valkey-cli did not return within #{TIMEOUT}s", false]
    end

    # Connection failures land on stderr and server error replies on
    # stdout; both mean the command did not work, so read them together.
    reply = (shell.stdout + shell.stderr).strip
    [reply, shell.exitstatus.zero? && !reply.match?(ERROR_REPLY)]
  end

  def sentinel(args, port: SENTINEL_PORT)
    cli(['sentinel'] + args, port: port)
  end

  # valkey-cli renders map replies as alternating name/value lines. A
  # trailing odd line means the reply was not a map at all; drop it
  # rather than raising an ArgumentError in front of an operator.
  def pairs(reply)
    lines = reply.lines.map(&:chomp)
    lines.pop if lines.length.odd?
    lines.each_slice(2).to_h
  end

  # 'INFO replication' from one member; nil when unreachable.
  def info_replication(host, port, pass)
    out, ok = cli(['info', 'replication'], host: host, port: port, pass: pass)
    return unless ok && out.include?('role:')
    out.lines.filter_map do |line|
      key, _, value = line.chomp.chomp("\r").partition(':')
      [key, value] unless key.start_with?('#') || value.empty?
    end.to_h
  end

  # Monitored service names known to the local sentinel.
  def sentinel_services(port: SENTINEL_PORT)
    out, ok = sentinel(['masters'], port: port)
    return [] unless ok
    lines = out.lines.map(&:chomp)
    lines.each_index.select { |i| lines[i] == 'name' }.map { |i| lines[i + 1] }
  end

  # One service name: --service wins, else the single monitored one.
  def resolve_service(name, port: SENTINEL_PORT)
    return name if name
    services = sentinel_services(port: port)
    abort 'ERROR: the local sentinel monitors no services.' if services.empty?
    return services.first if services.one?
    abort "ERROR: sentinel monitors several services (#{services.join(', ')}); pick one with --service."
  end

  def master_details(service, port: SENTINEL_PORT)
    out, ok = sentinel(['master', service], port: port)
    abort "ERROR: sentinel does not know service '#{service}': #{out}" unless ok && out.include?('name')
    pairs(out)
  end

  # Per-replica detail hashes; the reply is one flat alternating list
  # for all replicas, each entry restarting at 'name'.
  def replica_details(service, port: SENTINEL_PORT)
    out, ok = sentinel(['replicas', service], port: port)
    return [] unless ok
    lines = out.lines.map(&:chomp)
    starts = lines.each_index.select { |i| lines[i] == 'name' }
    starts.each_with_index.map do |start, idx|
      stop = starts[idx + 1] || lines.length
      lines[start...stop].each_slice(2).to_h
    end
  end
end
