# frozen_string_literal: true

# Cases to check:
# Insertion at top of file
# Insertion in an empty file
# Insertion in a file with only newlines
# Insertion at the bottom of a file

# Initial commit is pretty weird...
# Accesses shouldn't change (right now, due to file recreation, it does)
# New files / deleted files should remain stashed in the end

require_relative "spec_helper"

RSpec.describe GitAutoFixup do

  each_fixture do |fixture, example_chunk, section_chunk|
    skip if example_chunk.name.include?("(SKIP)") || section_chunk.name.include?("(SKIP)")
    gaf = nil
    Dir.mktmpdir("git_auto_fixup_test") do |root|
      g = Git.init(root)
      g.commit("Initial commit", allow_empty: true)
      new_commits_from_fixture(g, fixture, filename: "my_file.txt")

      staged_file_content = commit_short_form_to_full_form(fixture.staged_file_before_execution).join

      File.write("#{root}/my_file.txt", staged_file_content)
      g.add("my_file.txt")

      io = StringIO.new
      Dir.chdir(root) do
        options = {rebase_limit: `git rev-list --max-parents=0 HEAD`.strip, output: io}
        begin
          gaf = GitAutoFixup.new(options.merge(fixture.run_options))
          gaf.run
        ensure
          e = $!
          if %w(always).include?(ENV['RUN_PRY']) || e && %w(1 true).include?(ENV['RUN_PRY'])
            puts
            puts e
            puts root
            binding.pry
          end
        end
      end

      gaf.number_of_failed_fixups.should == (fixture.test_options[:nb_merge_conflicts] || 0)

      commits = g.log.to_a.reverse.reject { |commit| commit.message == "Initial commit" }
      commits.zip(fixture.commits_after_execution) do |commit, expected|
        content = commit_full_form_to_short_form(g.show(commit, "my_file.txt").lines)
        content.should == expected
      end

      unstaged_diff = `git -C #{root} diff`
      staged_diff = `git -C #{root} diff --cached`

      # Should never leave differences unstaged
      unstaged_diff.should be_empty

      # Should always end up with the same code
      content_as_it_is_staged = `git -C #{root} show :my_file.txt`

      content_as_it_is_staged.should == staged_file_content

      if fixture.staged_file_before_execution == fixture.commits_after_execution.last
        staged_diff.should be_empty
      else
        staged_diff.should_not be_empty
      end
    end
  end
end
