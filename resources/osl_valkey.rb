resource_name :osl_valkey
provides :osl_valkey
unified_mode true
default_action :create

# Manages a valkey server. On AlmaLinux 9 (9.7+) and 10 the valkey
# package ships in AppStream and includes both valkey.service and
# valkey-sentinel.service with configs under /etc/valkey/.
#
# The config file is seeded once, not converged: valkey rewrites it at
# runtime (CONFIG REWRITE) when sentinel changes its replication role,
# so a fully managed template would fight the daemon and demote a
# promoted primary on every chef run. Bump config_version to force a
# re-seed + restart.

# Enables requirepass and masterauth (all members carry masterauth so
# a demoted ex-primary can resync after a failover).
property :pass, String, sensitive: true

# Primary host to replicate from; absent = standalone/primary.
property :replicaof, String
property :replicaof_port, Integer, default: 6379

property :port, Integer, default: 6379

# Value for a bind directive (e.g. '127.0.0.1 10.0.0.5'); absent binds
# all interfaces, guarded by protected-mode/auth and the firewall.
property :bind, String

property :appendonly, [true, false], default: false
property :maxmemory, String
property :maxmemory_policy, String
# '' disables RDB snapshots; unset keeps valkey's compiled-in schedule
property :save, String

# Refuse writes on a primary with fewer live replicas than this: an
# isolated ex-primary goes read-only instead of accepting writes the
# rest of the cluster never sees (split-brain guard). Leave unset on
# standalone servers, they have no replicas to satisfy it.
property :min_replicas_to_write, Integer
property :min_replicas_max_lag, Integer, default: 10

# Extra config directives, rendered as '<key> <value>' lines.
property :config, Hash, default: {}

property :config_version, Integer, default: 1

# Run as its own valkey@<name> unit instead of the packaged valkey.service
property :instance, [true, false], default: false

property :firewall, [true, false], default: true
property :osl_only, [true, false], default: true

action_class do
  def validate_name!
    name = new_resource.name
    return unless new_resource.instance
    # 21 keeps the valkey-<name> iptables chain within its 28-character limit
    return if name.match?(/\A[a-z0-9][a-z0-9_-]{0,20}\z/) && !%w(valkey sentinel).include?(name)
    raise ArgumentError, "osl_valkey: '#{name}' is not a usable instance name"
  end

  # One set of settings per unit and one unit per port; true on the first claim.
  # Errors name keys only, never values, so pass stays out of the logs.
  def claim!(unit, settings)
    state = node.run_state['osl_valkey'] ||= { 'units' => {}, 'ports' => {} }
    owner = state['ports'][settings[:port]]
    raise "osl_valkey: port #{settings[:port]} is already used by #{owner}" if owner && owner != unit

    seen = state['units'][unit]
    if seen && seen != settings
      keys = (seen.keys | settings.keys).reject { |k| seen[k] == settings[k] }
      raise "osl_valkey: #{unit} is declared twice with different #{keys.join(', ')}"
    end

    state['ports'][settings[:port]] = unit
    state['units'][unit] = settings
    seen.nil?
  end
end

action :create do
  validate_name!
  instance = new_resource.instance
  unit = osl_valkey_unit(new_resource.name, instance)
  conf = osl_valkey_conf(new_resource.name, instance)
  config = osl_valkey_config(new_resource.config, new_resource.maxmemory, new_resource.save)
  settings = {
    appendonly: new_resource.appendonly,
    bind: new_resource.bind,
    config: config,
    config_version: new_resource.config_version,
    firewall: new_resource.firewall,
    maxmemory_policy: new_resource.maxmemory_policy,
    min_replicas_max_lag: new_resource.min_replicas_max_lag,
    min_replicas_to_write: new_resource.min_replicas_to_write,
    osl_only: new_resource.osl_only,
    pass: new_resource.pass,
    port: new_resource.port,
    replicaof: new_resource.replicaof,
    replicaof_port: new_resource.replicaof_port,
  }

  if claim!(unit, settings)
    node.default['osl-valkey']['instances'][new_resource.name] = {
      'config' => conf,
      'host' => osl_valkey_host(new_resource.bind),
      'port' => new_resource.port,
    }
  end

  osl_firewall_port(instance ? "valkey-#{new_resource.name}" : 'valkey') do
    ports [new_resource.port.to_s]
    osl_only new_resource.osl_only
  end if new_resource.firewall

  package 'valkey'

  # Recommended by valkey for background saves / AOF rewrites (the
  # fork can transiently need more memory than is free).
  sysctl 'vm.overcommit_memory' do
    value 1
  end if osl_valkey_forks?(new_resource.appendonly, config['save'], new_resource.replicaof, new_resource.min_replicas_to_write)

  if instance
    unless [6379, 16379, 26379].include?(new_resource.port)
      # selinux_port checks the current label with seinfo; without it every run re-adds
      package %w(policycoreutils-python-utils setools-console)

      selinux_port new_resource.port.to_s do
        protocol 'tcp'
        secontext 'redis_port_t'
      end
    end

    directory "/var/lib/valkey/#{new_resource.name}" do
      owner 'valkey'
      group 'valkey'
      mode '0750'
    end

    # The packaged valkey.service, templated. A shared RuntimeDirectory would be
    # removed whenever any one instance stopped.
    systemd_unit 'valkey@.service' do
      content(
        'Unit' => {
          'Description' => 'Valkey instance %i',
          'After' => 'network.target network-online.target',
          'Wants' => 'network-online.target',
        },
        'Service' => {
          'Type' => 'notify',
          'User' => 'valkey',
          'Group' => 'valkey',
          'WorkingDirectory' => '/var/lib/valkey/%i',
          'ExecStart' => '/usr/bin/valkey-server /etc/valkey/%i.conf --daemonize no --supervised systemd',
          'RuntimeDirectory' => 'valkey-%i',
          'RuntimeDirectoryMode' => '0755',
          'LimitNOFILE' => 10240,
          'Restart' => 'on-failure',
          'RestartSec' => '5s',
        },
        'Install' => {
          'WantedBy' => 'multi-user.target',
        }
      )
      verify false
      action :create
    end
  else
    directory '/etc/systemd/system/valkey.service.d'

    file '/etc/systemd/system/valkey.service.d/restart.conf' do
      content osl_valkey_restart_drop_in
      notifies :run, 'execute[valkey: daemon-reload]', :immediately
    end

    execute 'valkey: daemon-reload' do
      command 'systemctl daemon-reload'
      action :nothing
    end
  end

  # Declared before the seed so :immediately can restart it; an instance has
  # no packaged defaults to run on, so it only starts once seeded.
  service unit do
    action(instance ? :nothing : [:enable, :start])
  end

  marker = osl_valkey_marker(conf)

  template conf do
    source 'valkey.conf.erb'
    cookbook 'osl-valkey'
    owner 'valkey'
    group 'valkey'
    mode '0640'
    sensitive true
    variables settings.merge(
      dir: instance ? "/var/lib/valkey/#{new_resource.name}" : '/var/lib/valkey',
      logfile: "/var/log/valkey/#{instance ? new_resource.name : 'valkey'}.log"
    )
    not_if { valkey_config_seeded?(marker, new_resource.config_version) }
    notifies :restart, "service[#{unit}]", :immediately
  end

  file marker do
    content "#{new_resource.config_version}\n"
  end

  service unit do
    action [:enable, :start]
  end if instance
end

# Stops and disables the server. Data under /var/lib/valkey and firewall rules
# are kept (osl_firewall_port has no remove action).
action :delete do
  validate_name!
  instance = new_resource.instance
  unit = osl_valkey_unit(new_resource.name, instance)
  conf = osl_valkey_conf(new_resource.name, instance)

  service unit do
    action [:stop, :disable]
  end

  file osl_valkey_marker(conf) do
    action :delete
  end

  if instance
    file conf do
      action :delete
    end
  else
    file '/etc/systemd/system/valkey.service.d/restart.conf' do
      action :delete
      notifies :run, 'execute[valkey: daemon-reload]', :immediately
    end

    execute 'valkey: daemon-reload' do
      command 'systemctl daemon-reload'
      action :nothing
    end
  end
end
