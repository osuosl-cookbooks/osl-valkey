current_dir = File.dirname(__FILE__)
node_name 'fakeclient'
client_key "#{current_dir}/fakeclient.pem"
validation_client_name 'chef-validator'
validation_key "#{current_dir}/validator.pem"
chef_server_url "http://#{ENV['CHEF_SERVER']}:8889"
cache_type 'BasicFile'
cache_options(path: "#{ENV['HOME']}/.chef/checksums")
cookbook_path ["#{current_dir}/../../cookbooks"]
role_path "#{current_dir}/../integration/roles"
