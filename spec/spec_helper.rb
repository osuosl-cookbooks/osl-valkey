require 'chefspec'
require 'chefspec/berkshelf'
require 'stringio'
require_relative '../files/valkey_tools'

# The operator scripts require the library by the path it is installed
# to; register the repo copy loaded above as satisfying that, so the
# scripts can be loaded in-process by ScriptRunner.
$LOADED_FEATURES << '/usr/local/lib/valkey_tools.rb'

ScriptResult = Struct.new(:stdout, :stderr, :status)

# Runs one of the cookbook's operator scripts in-process: the scripts
# execute on load, so ARGV is swapped in, output is captured, and the
# SystemExit they end on is reported as an exit status (abort => 1).
module ScriptRunner
  def run_script(name, *argv)
    out = StringIO.new
    err = StringIO.new
    original_streams = [$stdout, $stderr]
    original_argv = ARGV.dup
    $stdout = out
    $stderr = err
    status = 0

    begin
      ARGV.replace(argv)
      load File.expand_path("../files/#{name}", __dir__)
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout, $stderr = original_streams
      ARGV.replace(original_argv)
    end

    ScriptResult.new(out.string, err.string, status)
  end
end

ALMA_9 = {
  platform: 'almalinux',
  version: '9',
}.freeze

ALMA_10 = {
  platform: 'almalinux',
  version: '10',
}.freeze

ALL_PLATFORMS = [
  ALMA_9,
  ALMA_10,
].freeze

RSpec.configure do |config|
  config.log_level = :warn
  config.include ScriptRunner
end
