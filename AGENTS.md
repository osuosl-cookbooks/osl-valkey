# AGENTS.md

Context for AI assistants working in this cookbook.

## What this cookbook does

Manages valkey server and sentinel from the distro `valkey` package (EL9.7+
and EL10 AppStream, which ships both services plus the configs under
`/etc/valkey/`). Two resources are the whole public surface: `osl_valkey`
and `osl_valkey_sentinel`. The default recipe is a bare standalone server,
mainly so there is something for the `default` kitchen suite to converge.

The first consumer is `osl-openstack`, which builds a distributed-lock
(tooz) tier for three OpenStack clouds on the shared mq nodes. Treat the
operator tooling as production-critical: it decides whether it is safe to
take a node down.

## Toolchain

- **Cookstyle:** `cinc exec cookstyle` (not raw `cookstyle`). `-a` to auto-fix.
- **ChefSpec:** `cinc exec rspec` from the cookbook root.
- **Kitchen:** `kitchen.yml` uses the **`cinc_infra`** provisioner - do not
  "modernize" it to `chef_infra` with `product_name: cinc`, that is the org
  convention.
- If `cinc exec rspec` dies with `Gem::ConflictError` on rspec-support, a
  stray rspec has been installed into `~/.chef-osuosl/gem` (an inspec run
  does this). Isolate to the workstation gems:
  `GEM_HOME=/opt/cinc-workstation/embedded/lib/ruby/gems/3.4.0 GEM_PATH=$GEM_HOME /opt/cinc-workstation/embedded/bin/rspec`

## The configs are seeded, not converged

valkey and sentinel **rewrite their own config files at runtime** - sentinel
persists myid, epochs, discovered members and failover state; valkey
rewrites `replicaof` when sentinel changes its role. A normally converged
template would fight the daemons and revert a promoted primary on every chef
run, so each resource writes its config **once** and records
`config_version` in a marker file (`/etc/valkey/.valkey.conf.chef`,
`/etc/valkey/.sentinel.conf.chef`).

Consequences worth remembering:

- Editing a template alone changes nothing on existing nodes. Any template
  or property change must ship with a `config_version` bump to reach them.
- Do not assert the seeded file **mode** in tests. The daemons rewrite these
  files via temp-file-plus-rename, which lands at 0644. Ownership survives;
  what actually contains the passwords is `/etc/valkey` being `0750`.

## Operator tooling

`osl_valkey_sentinel` installs `valkey-status` and `valkey-failover` (Ruby
ports of the ha-valkey ansible role's python scripts) plus the shared
`/usr/local/lib/valkey_tools.rb`.

- They run on **cinc's embedded ruby** (`#!/opt/cinc/embedded/bin/ruby`),
  matching osl-nrpe's plugins. AlmaLinux ships no system ruby and
  `/usr/bin/env ruby` finds nothing - that shebang is load-bearing.
- They shell out with **mixlib-shellout**, not open3 - it ships in the same
  omnibus as the ruby in the shebang, and it bounds each call with a
  timeout so one wedged member cannot hang a status check.
- **`valkey-cli` exits 0 on server error replies.** `NOQUORUM ...` and
  `ERR ...` come back with status 0, so `ValkeyTools.cli` marks a known
  error prefix as a failure. Do not "simplify" that back to the exit status
  alone; it silently disarms both quorum guards, which is how a forced
  promotion on a quorum-less tier got shipped once already.
- Read **both** streams: connection failures land on stderr while server
  error replies land on stdout.
- The password reaches valkey-cli through `REDISCLI_AUTH`, never argv. There
  is a test asserting exactly that; keep it.

## Sentinel and auth

Sentinel **does** support `requirepass` - the resource exposes it, and
`bind` too. The OpenStack lock tier leaves both unset because *tooz 2.10.1
cannot send a sentinel password*, and compensates with an OSL-only firewall
rule. That is a client limitation, not a daemon one; do not write it up as
"sentinel takes no auth", which is what licensed shipping an unauthenticated
admin port without a second thought.

## Testing layout

One inspec profile, `test/integration/valkey`, serves every suite. Each
kitchen suite (and each multi-node system) selects the controls that apply
and passes inputs for whatever its run list configured, so no fact is
asserted in two controls. Inputs must stay **scalars** - an array-valued
`input()` crashes `inspec check`; `members` is a comma-separated string.

Multi-node (`kitchen.multi-node.yml`) builds a real three-node cluster with
terraform and runs a genuine failover. No control assumes which member is
primary; each resolves that from sentinel at runtime, so `kitchen verify` is
re-runnable against a cluster in any state.

`spec/unit/test_wiring_spec.rb` cross-checks the run lists, profile paths
and control names that exist only as strings in `main.tf` and the kitchen
configs. It exists because a renamed role once cost a full cloud build to
discover.

When writing tests, stub what the tool **really** returns. Two specs once
stubbed `['NOQUORUM ...', false]`, a pair `valkey-cli` cannot produce, so
they were green against a world that did not exist while the guard they
covered was dead.

## Versioning and CHANGELOG

Do not bump `metadata.rb`'s `version` manually, and do not add
`CHANGELOG.md` entries. The OSL Jenkins pipeline owns both - version bumps
land as `Automatic patch-level version bump to vX.Y.Z by Jenkins`, and the
CHANGELOG is generated from PR titles/descriptions.

Note `supports` keys on the platform name, so a second `supports
'almalinux'` line silently replaces the first. Use one line with a range.

## Quick checks before opening a PR

```bash
cd /data-nvme/git/osl/chef-repo/osuosl-cookbooks/osl-valkey
cinc exec cookstyle
cinc exec rspec
cinc exec inspec check test/integration/valkey
terraform validate
```

Single-node kitchen is cheap. Multi-node builds four VMs and takes several
minutes; run it when changing the resources, the templates, the operator
scripts, or the terraform env.
