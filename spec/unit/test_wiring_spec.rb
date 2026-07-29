require 'json'
require 'yaml'
require_relative '../spec_helper'

# Run lists and profile paths in main.tf and the kitchen configs are
# plain strings that nothing else validates, so renaming a role, recipe
# or profile leaves a dangling reference that only surfaces part way
# through a cloud build. These check the wiring locally instead.
describe 'test environment wiring' do
  root = File.expand_path('../..', __dir__)
  main_tf = File.read(File.join(root, 'main.tf'))
  role_files = Dir[File.join(root, 'test/integration/roles/*.json')]
  kitchen_files = %w(kitchen.yml kitchen.multi-node.yml)

  # 'osl-valkey::default' lives in this cookbook, anything else in the
  # test cookbooks alongside it.
  def recipe_file(root, entry)
    cookbook, recipe = entry.split('::')
    dir = cookbook == 'osl-valkey' ? 'recipes' : "test/cookbooks/#{cookbook}/recipes"
    File.join(root, dir, "#{recipe || 'default'}.rb")
  end

  def run_list_entries(kitchen)
    (kitchen['suites'] || []).flat_map { |suite| suite['run_list'] || [] }
  end

  it 'bootstraps roles that exist' do
    referenced = main_tf.scan(/role\[([^\]]+)\]/).flatten.uniq
    available = role_files.map { |f| File.basename(f, '.json') }

    expect(referenced).to_not be_empty
    expect(referenced - available).to be_empty
  end

  it 'points every role at a recipe that exists' do
    role_files.each do |path|
      JSON.parse(File.read(path))['run_list'].each do |entry|
        recipe = entry[/\Arecipe\[([^\]]+)\]\z/, 1]
        next unless recipe
        expect(File.exist?(recipe_file(root, recipe)))
          .to be(true), "#{File.basename(path)} runs #{entry}, which does not exist"
      end
    end
  end

  it 'runs kitchen suites whose recipes exist' do
    kitchen_files.each do |file|
      run_list_entries(YAML.load_file(File.join(root, file))).each do |entry|
        recipe = entry[/\Arecipe\[([^\]]+)\]\z/, 1]
        next unless recipe
        expect(File.exist?(recipe_file(root, recipe)))
          .to be(true), "#{file} runs #{entry}, which does not exist"
      end
    end
  end

  it 'references inspec profiles and attrs files that exist' do
    kitchen_files.each do |file|
      body = File.read(File.join(root, file))
      body.scan(%r{-\s+(test/integration/\S+)}).flatten.uniq.each do |path|
        expect(File.exist?(File.join(root, path)))
          .to be(true), "#{file} references #{path}, which does not exist"
      end
    end
  end

  it 'selects controls that the profile defines' do
    defined_controls = Dir[File.join(root, 'test/integration/valkey/controls/*.rb')].flat_map do |path|
      File.read(path).scan(/^control '([^']+)'/).flatten
    end

    kitchen_files.each do |file|
      body = YAML.load_file(File.join(root, file))
      selected = (body.dig('verifier', 'systems') || []).flat_map { |s| s['controls'] || [] }
      selected += (body['suites'] || []).flat_map { |s| s.dig('verifier', 'controls') || [] }

      expect(selected.uniq - defined_controls)
        .to be_empty, "#{file} selects controls the profile does not define"
    end
  end
end
