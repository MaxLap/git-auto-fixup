# frozen_string_literal: true

require "fileutils"

# This script will go through staged changes and do fixups (changing last commits to have touched the modified lines).
# If the change spans multiple commits, this script will skip them.
# To be safe, this script prints out a command to undo the changes, so if something goes wrong, nothing is lost.
#
# To use it: Just stage the changes you want this script to try to auto fixup
#            Call the script
#            The script will do it's best. The changes that couldn't be handled will remain in the staged files

# TODO: See about using git apply --cached --unidiff-zero instead of changing any of the data from the disk
#       This will allow us to not even need a --hard reset for the undo!

#       To write to the index directly:
#       echo HI | git hash-object -w --stdin
#       # The sha is the output of hash-object
#       git update-index --add --cacheinfo 100644 c1e3b52e700b18a2b8e1d2616e9277ab447bddd0 foo.pl
#       # This allows us to set the index back to exactly what it was, so that things that were not handled are still staged


class GitAutoFixup
  INSERT_CHECK_TO_INSERT_WRAPPING = {recent: :around,
                                     around: :around,
                                     above: :above,
                                     below: :below,
                                    }

  class Transformation < Struct.new(:git_path, :from_first_line_i, :from_nb_lines, :into_first_line_i, :into_nb_lines)
    def insertion?
      from_nb_lines == 0
    end

    def replace_from_range
      if insertion?
        # The insertion is after the specified line
        # So we must do a manual increment
        (from_first_line_i + 1)...(from_first_line_i + 1)
      else
        (from_first_line_i)...(from_first_line_i + from_nb_lines)
      end
    end

    def replace_into_range
      (into_first_line_i)...(into_first_line_i + into_nb_lines)
    end

    def lines_for_blame(options = {})
      insert_wrapping = options[:insert_wrapping] || :around

      first_line_i = from_first_line_i
      last_line_i = from_first_line_i + from_nb_lines - 1

      if insertion?
        # First, we apply the basic logic for around. Then we pick what we want in the case.
        # `git blame` fails if we target before the first line
        first_line_i -= 1 if first_line_i > 0

        # `git blame` write nothing for lines aften the end, so no need for condition
        last_line_i += 1

        case insert_wrapping
        when :around
          # Already setup
        when :above
          # Can't go above the first line, just return nil
          return nil if from_first_line_i == 0

          last_line_i = first_line_i
        when :below
          first_line_i = last_line_i
        else
          raise "Bad insert_wrapping value: #{insert_wrapping}"
        end
      end

      [first_line_i, last_line_i]
    end

    def self.for_staged_file(git_path)
      # Some examples of the diff format
      #
      # @@ -15 +15 @@
      # Line 15 became line 15 after the change
      # Basically, ',1' is optionnal when only one line
      #
      # @@ -15,2 +15,2 @@
      # Starting at line 15 for 2 lines became line 15 for 2 lines after the change
      #
      # @@ -15,0 +16,2 @@
      # Starting at line 15 for 0 lines became line 16 for 2 lines after the change
      # This one is weird... when nb lines is 0, things actually happened after the line,
      # so things were inserted between line 15 and 16.

      diff_lines = `git diff -U0 #{git_path}`.lines

      diff_lines.grep(/^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/) do
        match = Regexp.last_match
        from_line_i = match[1].to_i - 1
        to_line_i = match[3].to_i - 1

        Transformation.new(
            git_path,
            from_line_i,
            (match[2] || 1).to_i,
            to_line_i,
            (match[4] || 1).to_i
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
  def initialize(options = {})
    rebase_limit = options[:rebase_limit] || "origin/master"
    insert_checks = options[:insert_checks] || :around
    @insert_checks = insert_checks

    @initial_ref = `git rev-parse HEAD`.strip
    # `git merge-base` is important to avoid moving the branch up further
    @rebase_limit_ref = `git merge-base #{rebase_limit} HEAD`.strip
    @stash_ref = `git stash create`.strip

    print_how_to_undo
  end

  def print_how_to_undo
    puts "To undo: git reset --hard #{@initial_ref}; git stash apply --index #{@stash_ref}"
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
    from_line, to_line = transformation.lines_for_blame(insert_wrapping: insert_wrapping)
    return nil if from_line.nil?

    blame_lines = `git blame -l -L #{from_line + 1},#{to_line + 1} -s HEAD #{transformation.git_path}`.lines

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


  def copy_all_data
    @staged_git_paths = `git diff --diff-filter=AM --name-only --cached`.split("\n")
    @staged_git_paths.each do |git_path|
      File.write(absolute_from_git(git_path) + STAGED_COPY_SUFFIX, `git show :#{git_path}`)
    end

    @modified_git_paths = `git diff --diff-filter=AM --name-only`.split("\n")
    @modified_git_paths.each do |git_path|
      file = absolute_from_git(git_path)
      FileUtils.cp(file, file + MODIFIED_COPY_SUFFIX)
    end
  end

  def generate_fixups_for_staged_file(git_path)
    file = absolute_from_git(git_path)
    FileUtils.cp(file + STAGED_COPY_SUFFIX, file)
    transformations = Transformation.for_staged_file(git_path)

    transformations_and_refs = transformations.map do |transformation|
      ref = ref_for_transformation(transformation)
      next if ref.nil?

      [transformation, ref]
    end
    transformations_and_refs.compact!

    return if transformations_and_refs.empty?

    staged_lines = File.read(file + STAGED_COPY_SUFFIX).lines.to_a
    current_lines = `git show HEAD:#{git_path}`.lines.to_a

    # Starting from the bottom so that line numbers don't need to be changed
    transformations_and_refs.reverse_each do |transformation, ref|
      current_lines[transformation.replace_from_range] = staged_lines[transformation.replace_into_range]

      File.write(file, current_lines.join)


      system("git", "add", git_path.to_s)
      system("git", "commit", "--fixup", ref.to_s)
    end
  end

  def run
    copy_all_data
    system("git stash")

    @staged_git_paths.each do |git_path|
      generate_fixups_for_staged_file(git_path)
    end

    # Need the -i for autosquash. EDITOR=true is to skip the editor opening to let the usage do the interactive rebasem
    system({"EDITOR" => "true"}, "git", "rebase", "-i", "--autosquash", @rebase_limit_ref.to_s)

    @staged_git_paths.each do |git_path|
      file = absolute_from_git(git_path)
      FileUtils.mv(file + STAGED_COPY_SUFFIX, file)
      system("git", "add", git_path.to_s)
    end

    @modified_git_paths.each do |git_path|
      file = absolute_from_git(git_path)
      FileUtils.mv(file + MODIFIED_COPY_SUFFIX, file)
    end

    print_how_to_undo
  end
end
