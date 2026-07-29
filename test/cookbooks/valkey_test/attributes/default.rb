# Topology of the multi-node terraform env (see main.tf): valkey1 is
# the seeded primary on the private cluster network, the rest replicate
# from it, and every member runs a sentinel so the quorum is 2 of 3.
default['valkey_test']['primary_host'] = 'valkey1'
default['valkey_test']['primary_ip'] = '10.1.0.11'
default['valkey_test']['pass'] = 'multi-node-test'
default['valkey_test']['service_name'] = 'testlocks'
default['valkey_test']['quorum'] = 2
