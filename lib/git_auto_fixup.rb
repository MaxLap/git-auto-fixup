# frozen_string_literal: true

require "fileutils"
require "open3"

# This script will go through staged changes and do fixups (changing last commits to have touched the modified lines).
# If the change spans multiple commits, this script will skip them.
# To be safe, this script prints out a command to undo the changes, so if something goes wrong, nothing is lost.
#
# To use it: Just stage the changes you want this script to try to auto fixup
#            Call the script
#            The script will do it's best. The changes that couldn't be handled will remain in the staged files

# TODO: support git commit --no-verify

class GitExecuteError < StandardError
end

class GitAutoFixup
  INSERT_CHECK_TO_INSERT_WRAPPING = {recent: :around,
                                     around: :around,
                                     above: :above,
                                     below: :below,
                                    }

  class Transformation < Struct.new(:git_path, :from_first_line_0i, :from_nb_lines, :into_lines)
    def insertion?
      from_nb_lines == 0
    end

    # Because of the logic of how to ranges work, the ranges for special cases must be
    # * an insertion at the start: 0...0
    # * an insertion at the end: size...size
    def range_to_apply_edit_0i
      from_first_line_0i...(from_first_line_0i + from_nb_lines)
    end

    # For insertions, we check based on :insert_wrapping either the line above, below, or both.
    # For modifications, we check only the replaced lines.
    def lines_1i_for_blame(options = {})
      insert_wrapping = options[:insert_wrapping] || :around

      first_line_0i = from_first_line_0i
      last_line_0i = from_first_line_0i + from_nb_lines - 1

      if insertion?
        # First, we apply the basic logic for around. Then we pick what we want in the case.

        first_line_0i -= 1
        last_line_0i += 1

        case insert_wrapping
        when :around
          # Already setup
        when :above
          # Can't go above the first line, just return nil
          return nil if from_first_line_0i == 0

          last_line_0i = first_line_0i
        when :below
          first_line_0i = last_line_0i
        else
          raise "Bad insert_wrapping value: #{insert_wrapping}"
        end
      end

      # `git blame` fails if the start line is out of bound
      first_line_0i = 0 if first_line_0i < 0

      [first_line_0i + 1, last_line_0i + 1]
    end

    def self.all_for_staged_file(git_path, staged_content=nil)
      diff_lines = `git diff -U0 --cached #{git_path}`.lines
      staged_content ||= `git show :#{git_path}`
      staged_raw_lines = staged_content.lines.to_a
      all_for_diff(git_path, diff_lines, staged_raw_lines)
    end

    def self.all_for_diff(git_path, diff_lines, into_raw_lines)
      # The diff format is @@ -a,b +c,d @@
      # `a` and `c` are line number, `b` and `d` are number of lines
      # The `,b` and `,d` are omitted when their value is 1
      # The `-` pair is the location in the initial file that are "removed",
      # the `+` pair is the location in the final file that was "added"
      # The line numbers (`a` and `c`) are 1-indexed
      #
      # If `b` is 0, then it means its an insertion.
      # If `d` is 0, then it means its a removal. Those can be treated the same
      # as modifications
      #
      # For modifications, line_number is the first line affected, and number of lines
      # tells you how many lines, including the first, are part of that change in that file.
      #
      # For insertions, line_number is the line before the the place where the location will happen.
      # This means you can get a line_number of 0 here when inserting at the top of a file. 0, for
      # something that is 1-indexed is kinda odd but can make sense.
      #
      # Some examples of the diff format
      #
      # @@ -15 +15 @@
      # Line 15 became line 15 after the change
      #
      # @@ -15,2 +15,2 @@
      # Starting at line 15 for 2 lines became line 15 for 2 lines after the change
      #
      # @@ -15,0 +16,2 @@
      # Starting at line 15 for 0 lines became line 16 for 2 lines after the change
      # This one is weird... when nb lines is 0, things actually happened after the line,
      # so things were inserted between line 15 and 16.
      diff_lines.grep(/^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/) do
        match = Regexp.last_match

        into_line_0i = match[3].to_i - 1
        into_nb_lines = (match[4] || 1).to_i
        into_range_0i = into_line_0i...(into_line_0i + into_nb_lines)

        from_first_line_0i = match[1].to_i - 1
        from_nb_lines = (match[2] || 1).to_i

        if from_nb_lines == 0
          # In the diff, insertion happens after the specified line
          # For our logic, its easier to consider that it happens before the specified line
          from_first_line_0i += 1
        end

        Transformation.new(
            git_path,
            from_first_line_0i,
            from_nb_lines,
            (into_raw_lines[into_range_0i] if into_raw_lines)
        )
      end
    end
  end


  MODIFIED_COPY_SUFFIX = "-AUTO_FIXUP_INITIAL_MODIFIED"
  STAGED_COPY_SUFFIX = "-AUTO_FIXUP_INITIAL_STAGED"

  # rebase_limit: This is the limit of how far back this script can rebase.
  #               Will not alter that commit or before it. (default to master)
  # insert_checks: For insertions where nothing is modified, this decides how to select the commit to modify
  #                Possible values are: :above, takes the commit of the line above
  #                                     :below, takes the commit of the line below
  #                                     :around, takes the commit only if both above and below are the same
  #                                     :recent, takes most recent commit between above and below
  # output: IO to print to.
  def initialize(options = {})
    rebase_limit = options[:rebase_limit] || "origin/master"
    insert_checks = options[:insert_checks] || :around
    @insert_checks = insert_checks

    @initial_ref = `git rev-parse HEAD`.strip
    # `git merge-base` is important to avoid moving the branch up further
    @rebase_limit_ref = `git merge-base #{rebase_limit} HEAD`.strip
    # A stash that doesn't appear in the list of stashes, exactly what we want for the undo without
    # spamming the list of stashes
    @stash_ref = `git stash create`.strip
    @output = options[:output] || STDOUT
    @fixup_commit_refs = Set.new
    @fixup_commit_refs_that_failed = []
    print_how_to_undo
  end

  def print_how_to_undo
    @output.puts(how_to_undo_string)
  end

  def how_to_undo_string
    "To undo: git reset --hard #{@initial_ref}; git stash apply --index #{@stash_ref}"
  end

  def git_root
    @git_root ||= `git rev-parse --show-toplevel`.strip
  end

  def absolute_from_git(file)
    File.absolute_path(file, git_root)
  end


  def staged_modified_files
    # --cached means only only for staged changes
    `git diff --diff-filter=AM --name-only --cached`
      .lines
      .map(&:chomp)
      .map { |file| File.absolute_path(file) }
  end

  def ref_for_transformation(transformation)
    insert_wrapping = INSERT_CHECK_TO_INSERT_WRAPPING.fetch(@insert_checks)
    from_line_1i, to_line_1i = transformation.lines_1i_for_blame(insert_wrapping: insert_wrapping)
    return nil if from_line_1i.nil?

    blame_lines = git(*%W(blame -l -L #{from_line_1i},#{to_line_1i} -s HEAD #{transformation.git_path})).lines

    # Lines can start with a ^ for "boundary commits", which in our case means the root commits
    refs = blame_lines.map { |l| l[/\^?\w+/] }.uniq

    return nil if refs.any? { |ref| ref.start_with?("^") }

    return most_recent_ref(*refs) if @insert_checks == :recent

    return nil if refs.size != 1

    ref = refs.first
    return nil unless ref_within_rebase_limit?(ref)

    ref
  end

  def most_recent_ref(*refs)
    refs.max_by { |ref| `git rev-list --count #{ref}`.strip.to_i }
  end

  def oldest_ref(*refs)
    refs.min_by { |ref| `git rev-list --count #{ref}`.strip.to_i }
  end

  def ref_within_rebase_limit?(ref)
    oldest = oldest_ref(ref, @rebase_limit_ref)
    oldest == @rebase_limit_ref
  end

  # Used for test system
  # Fixups that made merge conflicts
  def number_of_failed_fixups
    @fixup_commit_refs_that_failed.size
  end

  def store_staged_data
    @staged_content = {}
    @staged_transformations_per_git_path = {}

    staged_git_paths = `git diff --diff-filter=AM --name-only --cached`.split("\n")
    staged_git_paths.each do |git_path|
      content = `git show :#{git_path}`
      @staged_content[git_path] = content
      @staged_transformations_per_git_path[git_path] = Transformation.all_for_staged_file(git_path, content)
    end
  end

  def generate_fixups_for_staged_file(git_path)
    current_lines = `git show HEAD:#{git_path}`.lines.to_a
    # Starting from the bottom so that line numbers don't need to be changed
    @staged_transformations_per_git_path[git_path].reverse_each do |transformation|
      ref = ref_for_transformation(transformation)
      next if ref.nil?

      current_lines[transformation.range_to_apply_edit_0i] = transformation.into_lines

      # We are writing to the index directly
      hash, _status = Open3.capture2("git hash-object -w --stdin", stdin_data: current_lines.join)
      hash = hash.strip

      # TODO: We want the mode to be the same it was before
      system("git", "update-index", "--add", "--cacheinfo", "100644,#{hash},#{git_path}")
      system("git", "commit", "--quiet", "--fixup", ref.to_s)

      @fixup_commit_refs << `git rev-parse HEAD`.strip
    end
  end

  def run
    store_staged_data

    system("git commit --quiet -m 'auto-fixup temp commit of staged changes'")
    # The only simple way of storing all that is currently staged is to make a commit
    @commit_with_staged_diff_ref = `git rev-parse HEAD`.strip

    # Remove everything from the staged area
    system("git reset --quiet #{@initial_ref}")

    @staged_content.each_key do |git_path|
      generate_fixups_for_staged_file(git_path)
    end

    # Need the -i for autosquash.
    # EDITOR=true is to skip the editor opening to let the usage do the interactive rebase
    # --autostash handles the other local changes by stashing them before and after
    command_to_run = [{"EDITOR" => "true"}, *%W(rebase -i --autosquash --autostash #{@rebase_limit_ref})]

    while command_to_run
      begin
        git(*command_to_run)
        command_to_run = nil
      rescue GitExecuteError => e
        raise if `git diff --name-only --diff-filter=U`.empty?
        # We are in a merge conflict
        failed_commit_ref = `git rev-parse REBASE_HEAD`.strip
        if @fixup_commit_refs.include?(failed_commit_ref)
          # The conflict was in one of our fixups, skip it, it will end up in the still staged changes
          @fixup_commit_refs_that_failed << failed_commit_ref
          command_to_run = %w(rebase --skip)
        else
          raise
        end
      end
    end

    final_ref = `git rev-parse HEAD`.strip

    # Reapply the changes that generated merge conflicts. By skipping them,
    # these changes were removed from the local dir
    @fixup_commit_refs_that_failed.each do |ref|
      system("git cherry-pick #{ref} --no-commit")
    end

    # We re-stage changes that were initially staged by going to the commit with all staged changes
    # and then `reset --soft` to our final commit. (--soft will leave the changes as staged)
    system("git reset --quiet #{@commit_with_staged_diff_ref}")
    system("git reset --soft --quiet #{final_ref}")

    print_how_to_undo
  end

  def git(*args)
    if args.first.is_a?(Hash)
      env = args.first
      args = args[1..-1]
      git_cmd = [env, "git", *args.map(&:to_s)]
    else
      git_cmd = ["git", *args.map(&:to_s)]
    end

    stdout_and_stderr_str, status = Open3.capture2e(*git_cmd)
    exitstatus = status.exitstatus

    if exitstatus > 1 || (exitstatus == 1 && stdout_and_stderr_str != '')
      raise GitExecuteError.new("Command `#{git_cmd.join(" ")}` :\n#{stdout_and_stderr_str.gsub("\r", "\n")}")
    end

    stdout_and_stderr_str
  end
end
