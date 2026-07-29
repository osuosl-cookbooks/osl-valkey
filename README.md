# osl-valkey

Manages valkey server and sentinel. Both come from the distro `valkey`
package (AppStream on AlmaLinux 9.7+ and 10), which ships
`valkey.service` and `valkey-sentinel.service` with configs under
`/etc/valkey/`.

Both config files are seeded once and then left alone: valkey and
sentinel rewrite their own configs at runtime (`CONFIG REWRITE` on
role change; sentinel persists myid, epochs, discovered members and
failover state), so a continuously converged template would fight the
daemons and revert failover state on every chef run. Each resource
records its `config_version` in a marker file
(`/etc/valkey/.valkey.conf.chef`, `/etc/valkey/.sentinel.conf.chef`);
bump the property to force a re-seed plus restart, and treat that as a
small maintenance action since it also resets any runtime failover
state back to the seeded topology.

## Requirements

### Platforms

- AlmaLinux 9 (9.7+)
- AlmaLinux 10

### Cookbooks

- osl-firewall

## Attributes

None; everything is driven through resource properties.

## Resources

### osl_valkey

A valkey server.

```ruby
osl_valkey 'default' do
  pass 'secret'                  # requirepass + masterauth; omit for no auth
  replicaof 'valkey1.example.org' # replicate from this primary; omit for standalone
  appendonly true                # AOF persistence (default false)
  maxmemory_policy 'noeviction'  # omit to use the compiled-in default
  config('tcp-keepalive' => 60)  # extra '<directive> <value>' lines
end
```

Other properties: `port` (6379), `replicaof_port` (6379), `bind`
(rendered as a bind line; default binds all interfaces, guarded by
protected-mode/auth and the firewall), `min_replicas_to_write` (unset;
set to 1 on replicated deployments so an isolated ex-primary goes
read-only instead of accepting writes the rest of the cluster never
sees), `min_replicas_max_lag` (10, only rendered with
`min_replicas_to_write`), `config_version` (1), `firewall` (true,
opens the port via `osl_firewall_port`), `osl_only` (true).

The resource also sets `vm.overcommit_memory = 1`, recommended by
valkey for background saves and AOF rewrites.

### osl_valkey_sentinel

A sentinel monitoring one service; the resource name is the sentinel
service name clients ask for. `pass` is what sentinel uses to reach the
monitored valkeys (`auth-pass`); `requirepass` is what sentinel demands
from its own clients.

```ruby
osl_valkey_sentinel 'mylocks' do
  monitor_host 'valkey1.example.org' # the initial primary; default 127.0.0.1
  quorum 2                           # default 1
  pass 'secret'
  requirepass 'another-secret'       # omit only if the clients cannot send it
end
```

Set `requirepass` unless your clients cannot authenticate to sentinel:
with it unset the port accepts any client the firewall admits, and
`SENTINEL SET`, `SENTINEL FAILOVER` and friends are privileged. The
OpenStack lock tier is one such exception - tooz 2.10.1 has no way to
send a sentinel password - and it compensates with an OSL-only firewall
rule. `bind` narrows the listener further.

Other properties: `port` (26379), `bind` (unset, binds all
interfaces), `monitor_port` (6379), `down_after_ms` (5000),
`failover_timeout_ms` (60000), `parallel_syncs` (1),
`resolve_hostnames` (true, also enables announce-hostnames),
`config_version` (1), `firewall` (true), `osl_only` (true).

## Operator tooling

`osl_valkey_sentinel` installs two root-oriented scripts (Ruby ports
of the ha-valkey ansible role's python tooling, adapted to a plain
sentinel deployment). Both resolve the service name through the local
sentinel and read the valkey password from `/etc/valkey/valkey.conf`,
passing it via `REDISCLI_AUTH` so it never appears in process args.

- `valkey-status`: sentinel's view (primary, quorum, ckquorum,
  membership) plus live `INFO replication` from every member; exits
  non-zero when a member is down or a replica link is broken.
- `valkey-failover [--yes]`: orchestrated manual failover for
  maintenance. Preflights quorum, replica presence and full write
  acknowledgement (`WAIT`), triggers `SENTINEL FAILOVER`, waits for
  the switch, and then waits for the old primary to rejoin as a
  replica *with its link up* before reporting success - a node that is
  demoted but still syncing is not yet a usable replacement, and
  exiting early would say the cluster is ready to lose a node when it
  is not. Prefer this over stopping the primary when patching or
  rebooting it.

## Recipes

- `default`: a standalone unauthenticated `osl_valkey 'default'`.

## Testing

Every suite runs the one profile in `test/integration/valkey` and
selects the controls that apply, passing inputs for whatever its run
list configured. Nothing is asserted in more than one control:

| control | scope | covers |
|---|---|---|
| `server` | any valkey server | package, service, port, seeded file ownership and version marker, `vm.overcommit_memory`, auth (or its absence), and every configured directive read back with `CONFIG GET` |
| `firewall` | any node | the chain and rule `osl_firewall_port` created, and the absence of the sentinel chain where no sentinel runs |
| `sentinel` | any sentinel | service, port, seeded directives it preserves across rewrites, monitor settings read back with `SENTINEL MASTER`, quorum, and the operator tooling |
| `cluster` | multi-node | cross-member reachability, sentinel's current primary, this member's role coherence |
| `replication` | multi-node, one system | the current primary carries every replica online, the replicas follow it and refuse writes, and a `WAIT`-confirmed write is readable from each of them |
| `failover` | multi-node | a real orchestrated failover, last |

Inputs (all scalars, since an array-valued input crashes `inspec check`) let one control
serve every suite: `valkey_pass`, `valkey_port`, `bind`, `appendonly`,
`maxmemory_policy`, `min_replicas_to_write`, `min_replicas_max_lag`,
`extra_config` (`directive=value` pairs), `config_version`, `firewall`,
`sentinel`, `service_name`, `sentinel_port`, `quorum`, `down_after_ms`,
`failover_timeout_ms`, `parallel_syncs`, `sentinel_count`,
`sentinel_replicas`, `sentinel_requirepass`, `primary_ip`, and
`members`.

`kitchen.yml` runs the single-node suites on AlmaLinux 9 and 10:
`default` (a bare unauthenticated server) and `server_sentinel`, which
exercises auth, `bind`, AOF, the eviction policy, an extra config
directive and non-default sentinel timings.

### Multi-node

`kitchen.multi-node.yml` builds a real three-node cluster with
terraform: `valkey1`, `valkey2` and `valkey3` on a private network
(10.1.0.11-13), each bootstrapped against a throwaway chef-zero with
`role[valkey_cluster]`. That role runs `valkey_test::cluster`, which
seeds `valkey1` as the primary and the other two as replicas by
comparing each node's hostname to the configured primary, with a
sentinel on every member (quorum 2).

``` console
# Only need to run this once
$ chef exec rake create_key
$ KITCHEN_YAML=kitchen.multi-node.yml kitchen test multi-node
```

Each node runs `server`, `firewall`, `sentinel` and `cluster`, and
`valkey1` also runs `replication`, which is cluster-wide and needs no
repeating per node; the topology inputs come from
`test/integration/attrs/cluster.yml`. A fourth system targets `valkey1`
again and runs only `failover`, last: it performs a real orchestrated
failover with `valkey-failover --yes`, then asserts a different member
was promoted, the old primary rejoined as a replica, quorum still
holds, and the value written by `replication` survived the switch.

`kitchen verify` can be re-run as often as you like. No control
assumes which member is primary - each resolves that from sentinel at
runtime - so verifying an already failed-over cluster simply moves the
primary again. That chef seeds `valkey1` specifically is asserted by
the unit specs for `valkey_test::cluster` instead.

### Access the nodes

kitchen-terraform doesn't support `kitchen console`, so log in with the
addresses terraform reports:

``` bash
$ ssh almalinux@$(terraform output -raw valkey1)
$ terraform output
```

All three nodes are configured by the chef-zero container, so you can
re-run `cinc-client` on any of them during development. Local cookbook
edits reach them only once they are uploaded, which `terraform apply`
(and so `kitchen converge`) does on every run; to push an edit without
a converge, run `CHEF_SERVER="$(terraform output -raw chef_zero)" rake
knife_upload` first. **Include the knife config, or you will be talking
to the production chef server:**

``` bash
$ CHEF_SERVER="$(terraform output -raw chef_zero)" knife node list -c test/chef-config/knife.rb
```

## Contributing

1. Fork the repository on GitHub
1. Create a named feature branch (like `username/add_component_x`)
1. Write tests for your change
1. Write your change
1. Run the tests, ensuring they all pass
1. Submit a pull request on GitHub

## License and Authors

- Author:: Oregon State University <chef@osuosl.org>

```text
Copyright:: 2026, Oregon State University

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```
