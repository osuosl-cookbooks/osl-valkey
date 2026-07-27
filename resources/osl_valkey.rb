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
property :maxmemory_policy, String

# Refuse writes on a primary with fewer live replicas than this: an
# isolated ex-primary goes read-only instead of accepting writes the
# rest of the cluster never sees (split-brain guard). Leave unset on
# standalone servers, they have no replicas to satisfy it.
property :min_replicas_to_write, Integer
property :min_replicas_max_lag, Integer, default: 10

# Extra config directives, rendered as '<key> <value>' lines.
property :config, Hash, default: {}

property :config_version, Integer, default: 1

property :firewall, [true, false], default: true
property :osl_only, [true, false], default: true

action :create do
  osl_firewall_port 'valkey' do
    ports [new_resource.port.to_s]
    osl_only new_resource.osl_only
  end if new_resource.firewall

  package 'valkey'

  # Recommended by valkey for background saves / AOF rewrites (the
  # fork can transiently need more memory than is free).
  sysctl 'vm.overcommit_memory' do
    value 1
  end

  # Declared before the seed so it can be restarted via :immediately
  # (unified_mode executes in declaration order). First converge
  # briefly runs the packaged localhost-only defaults.
  service 'valkey' do
    action [:enable, :start]
  end

  marker = '/etc/valkey/.valkey.conf.chef'

  template '/etc/valkey/valkey.conf' do
    source 'valkey.conf.erb'
    cookbook 'osl-valkey'
    owner 'valkey'
    group 'valkey'
    mode '0640'
    sensitive true
    variables(
      appendonly: new_resource.appendonly,
      bind: new_resource.bind,
      config: new_resource.config,
      maxmemory_policy: new_resource.maxmemory_policy,
      min_replicas_max_lag: new_resource.min_replicas_max_lag,
      min_replicas_to_write: new_resource.min_replicas_to_write,
      pass: new_resource.pass,
      port: new_resource.port,
      replicaof: new_resource.replicaof,
      replicaof_port: new_resource.replicaof_port
    )
    not_if { valkey_config_seeded?(marker, new_resource.config_version) }
    notifies :restart, 'service[valkey]', :immediately
  end

  file marker do
    content "#{new_resource.config_version}\n"
  end
end
