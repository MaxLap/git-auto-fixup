# frozen_string_literal: true

# Cases to check:
# Insertion at top of file
# Insertion in an empty file
# Insertion in a file with only newlines
# Insertion at the bottom of a file
# Initial commit is pretty weird...

require_relative "spec_helper"

RSpec.describe GitAutoFixup do
  it "has a version number" do
    expect(GitAutoFixup::VERSION).not_to be nil
  end

  it "does something useful" do
    Dir.mktmpdir("git_auto_fixup_test") do |root|
      system("git init", chdir: root)
      system("git commit --allow-empty -m 'Initial commit'", chdir: root)

      File.write("#{root}/my_file.txt", <<-TXT)
        HELLO
        WORLD
      TXT
      system("git", "add", "my_file.txt", chdir: root)
      system("git commit -m 'Second commit'", chdir: root)

      File.write("#{root}/my_file.txt", <<-TXT)
        HELLO
        WORLD2
      TXT
      system("git", "add", "my_file.txt", chdir: root)
      system("git commit -m 'Third commit'", chdir: root)

      File.write("#{root}/my_file.txt", <<-TXT)
        HELLO
        WORLD3
      TXT
      system("git", "add", "my_file.txt", chdir: root)
      Dir.chdir(root) do
        GitAutoFixup.new(rebase_limit: `git rev-list --max-parents=0 HEAD`.strip).run
      end

      `git -C #{root} diff my_file.txt`.should be_empty
      `git -C #{root} diff --cached my_file.txt`.should be_empty
    end
  end
end
