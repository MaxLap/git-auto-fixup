# frozen_string_literal: true

require "bundler/setup"
require_relative "../lib/git_auto_fixup"
require "tmpdir"
require "pry"
require "git"
require "fileutils"
require "active_support/all"
require_relative "support/fixtures_helper"

RSpec.configure do |config|
  config.extend FixturesHelper
  config.include FixturesHelper

  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  # config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = [:expect, :should]
  end
end
