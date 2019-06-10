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
    Dir.mktmpdir("git_auto_fixup_test") do |root|
      g = Git.init(root)
      g.commit("Initial commit", allow_empty: true)
      fixture.commits_before_execution.each_with_index do |content, i|
        File.write("#{root}/my_file.txt", format_commit_to_lines(content).join)
        g.add("my_file.txt")
        g.commit("Commit ##{i+1}")
      end

      File.write("#{root}/my_file.txt", format_commit_to_lines(fixture.staged_file_before_execution).join)
      g.add("my_file.txt")

      Dir.chdir(root) do
        GitAutoFixup.new(rebase_limit: `git rev-list --max-parents=0 HEAD`.strip).run
      end

      commits = g.log.to_a.reverse.reject { |commit| commit.message == "Initial commit" }
      commits.zip(fixture.commits_after_execution) do |commit, expected|
        content = format_commit_to_spaces(g.show(commit, "my_file.txt").lines)
        content.should == expected
      end

      g.diff.should be_an_none
      g.diff('--cached').should be_an_none
    end
  end

  it "does something useful more nicely" do
    Dir.mktmpdir("git_auto_fixup_test") do |root|
      g = Git.init(root)

      g.commit("Initial commit", allow_empty: true)

      File.write("#{root}/my_file.txt", <<-TXT)
        HELLO
        WORLD
      TXT
      g.add("my_file.txt")

      g.commit("Second commit")

      File.write("#{root}/my_file.txt", <<-TXT)
        HELLO
        WORLD2
      TXT
      g.add("my_file.txt")
      g.commit("Third commit")

      File.write("#{root}/my_file.txt", <<-TXT)
        HELLO
        WORLD3
      TXT
      g.add("my_file.txt")

      Dir.chdir(root) do
        GitAutoFixup.new(rebase_limit: `git rev-list --max-parents=0 HEAD`.strip).run
      end

      g.diff.should be_an_none
      g.diff('--cached').should be_an_none
    end
  end
end
