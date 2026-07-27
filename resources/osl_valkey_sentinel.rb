resource_name :osl_valkey_sentinel
provides :osl_valkey_sentinel
unified_mode true
default_action :create

# Manages valkey-sentinel monitoring one service (the resource name is
# the sentinel service name clients ask for). Ships in the same valkey
# package as the server.
#
# sentinel.conf is seeded once, not converged: sentinel rewrites it
# continuously at runtime (myid, config epoch, discovered replicas and
# sentinels, failover state). Bump config_version to force a re-seed +
# restart, which also resets failover state to the seeded topology.

property :service_name, String, name_property: true

property :monitor_host, String, default: '127.0.0.1'
property :monitor_port, Integer, default: 6379
property :quorum, Integer, default: 1

# auth-pass sentinel uses to reach the monitored valkeys.
property :pass, String, sensitive: true

# Password sentinel demands from its own clients. Sentinel supports
# this, but a client has to be able to send it: tooz 2.10.1 (yoga)
# cannot, which is why the OpenStack lock tier leaves it unset and
# relies on the firewall. Set it wherever the clients can authenticate.
property :requirepass, String, sensitive: true

# Value for a bind directive (e.g. '127.0.0.1 10.0.0.5'). Absent binds
# all interfaces, which with no requirepass leaves 26379 open to
# everything the firewall admits.
property :bind, String

property :port, Integer, default: 26379
property :down_after_ms, Integer, default: 5000
property :failover_timeout_ms, Integer, default: 60000
property :parallel_syncs, Integer, default: 1

# Monitor/announce members by hostname instead of IP.
property :resolve_hostnames, [true, false], default: true

property :config_version, Integer, default: 1

property :firewall, [true, false], default: true
property :osl_only, [true, false], default: true

action :create do
  osl_firewall_port 'valkey_sentinel' do
    ports [new_resource.port.to_s]
    osl_only new_resource.osl_only
  end if new_resource.firewall

  package 'valkey'

  # Declared before the seed so it can be restarted via :immediately
  # (unified_mode executes in declaration order).
  service 'valkey-sentinel' do
    action [:enable, :start]
  end

  marker = '/etc/valkey/.sentinel.conf.chef'

  template '/etc/valkey/sentinel.conf' do
    source 'sentinel.conf.erb'
    cookbook 'osl-valkey'
    owner 'valkey'
    group 'valkey'
    mode '0640'
    sensitive true
    variables(
      bind: new_resource.bind,
      down_after_ms: new_resource.down_after_ms,
      failover_timeout_ms: new_resource.failover_timeout_ms,
      monitor_host: new_resource.monitor_host,
      monitor_port: new_resource.monitor_port,
      parallel_syncs: new_resource.parallel_syncs,
      pass: new_resource.pass,
      port: new_resource.port,
      quorum: new_resource.quorum,
      requirepass: new_resource.requirepass,
      resolve_hostnames: new_resource.resolve_hostnames,
      service_name: new_resource.service_name
    )
    not_if { valkey_config_seeded?(marker, new_resource.config_version) }
    notifies :restart, 'service[valkey-sentinel]', :immediately
  end

  file marker do
    content "#{new_resource.config_version}\n"
  end

  # Operator tooling (see README): status overview and orchestrated
  # manual failover, ported from the ha-valkey ansible role's python
  # scripts.
  cookbook_file '/usr/local/lib/valkey_tools.rb' do
    cookbook 'osl-valkey'
    mode '0644'
  end

  # These run on cinc's embedded ruby (see their shebang): AlmaLinux
  # ships no system ruby, and '/usr/bin/env ruby' finds nothing.
  %w(valkey-status valkey-failover).each do |tool|
    cookbook_file "/usr/local/bin/#{tool}" do
      source tool
      cookbook 'osl-valkey'
      mode '0755'
    end
  end
end
