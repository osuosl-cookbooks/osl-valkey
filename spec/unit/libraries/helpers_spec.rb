require_relative '../../spec_helper'
require_relative '../../../libraries/helpers'

describe OslValkey::Cookbook::Helpers do
  let(:helper) do
    Class.new do
      include OslValkey::Cookbook::Helpers
      attr_accessor :node, :family

      def platform_family?(f)
        family == f
      end
    end.new
  end

  {
    %w(rhel 9.1) => false,
    %w(rhel 9.7) => true,
    %w(rhel 9.8) => true,
    %w(rhel 10.0) => true,
    %w(rhel 8.10) => false,
    %w(debian 13.1) => false,
  }.each do |(family, version), expected|
    it "osl_valkey_supported? on #{family} #{version}" do
      helper.family = family
      helper.node = { 'platform_version' => version }
      expect(helper.osl_valkey_supported?).to eq expected
    end
  end

  it { expect(helper.osl_valkey_config({ save: '' }, nil, nil)).to eq('save' => '""') }
  it { expect(helper.osl_valkey_config({ 'save' => '900 1' }, '1gb', '')).to eq('save' => '""', 'maxmemory' => '1gb') }
  it { expect(helper.osl_valkey_config({}, nil, nil)).to eq({}) }

  it { expect(helper.osl_valkey_forks?(false, '""', nil, nil)).to be false }
  it { expect(helper.osl_valkey_forks?(false, nil, nil, nil)).to be true }
  it { expect(helper.osl_valkey_forks?(true, '""', nil, nil)).to be true }
  it { expect(helper.osl_valkey_forks?(false, '""', 'valkey1', nil)).to be true }
  it { expect(helper.osl_valkey_forks?(false, '""', nil, 1)).to be true }

  it { expect(helper.osl_valkey_host(nil)).to eq '127.0.0.1' }
  it { expect(helper.osl_valkey_host('0.0.0.0')).to eq '127.0.0.1' }
  it { expect(helper.osl_valkey_host('-::1 10.0.0.5')).to eq '::1' }
  it { expect(helper.osl_valkey_host('10.0.0.5 127.0.0.1')).to eq '10.0.0.5' }
  it { expect(helper.osl_valkey_marker('/etc/valkey/cache.conf')).to eq '/etc/valkey/.cache.conf.chef' }
end
