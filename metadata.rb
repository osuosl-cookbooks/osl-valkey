name              'osl-valkey'
maintainer        'Oregon State University'
maintainer_email  'chef@osuosl.org'
license           'Apache-2.0'
description       'Installs/Configures valkey server and sentinel'
issues_url        'https://github.com/osuosl-cookbooks/osl-valkey/issues'
source_url        'https://github.com/osuosl-cookbooks/osl-valkey'
chef_version      '>= 18.0'
version           '0.1.0'

depends           'osl-firewall'

# One line, not one per release: supports keys on the platform name, so
# a second almalinux line silently replaces the first.
supports          'almalinux', '>= 9.0'
