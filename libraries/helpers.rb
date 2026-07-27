module OslValkey
  module Cookbook
    module Helpers
      # Whether the config a marker guards was already seeded at this
      # config_version. Both daemons rewrite their own config at
      # runtime, so the file's own content is not comparable after the
      # first rewrite: the marker records what chef last seeded, and
      # bumping config_version is what triggers a re-seed.
      def valkey_config_seeded?(marker, config_version)
        ::File.exist?(marker) && ::File.read(marker).strip == config_version.to_s
      end
    end
  end
end

Chef::DSL::Recipe.include ::OslValkey::Cookbook::Helpers
Chef::Resource.include ::OslValkey::Cookbook::Helpers
