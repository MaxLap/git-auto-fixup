

module FixturesHelper
  extend self

  def each_fixture_chunk(&block)
    FixturesHelper.files.each do |file_chunk|
      describe file_chunk.name do
        file_chunk.rechunk(FixturesHelper::SECTION_REGEX).each do |section_chunk|
          describe section_chunk.name do
            section_chunk.rechunk(FixturesHelper::EXAMPLE_REGEX).each do |example_chunk|
              it(example_chunk.name + " (line #{example_chunk.first_line_no})") do
                self.instance_exec(example_chunk, section_chunk, file_chunk, &block)
              end
            end
          end
        end
      end
    end
  end

  def each_fixture(&block)
    each_fixture_chunk do |example_chunk, section_chunk, file_chunk|
      fixture = Fixture.new(example_chunk.lines)
      self.instance_exec(fixture, example_chunk, section_chunk, file_chunk, &block)
    end
  end

  # Turns "a b c d" into "a\nb\nc\nd\n"
  # Turns "a b c d\\" into "a\nb\nc\nd"
  def commit_short_form_to_full_form(string)
    string = string.strip
    if string.end_with?("\\")
      string = string[0...-1].strip
    else
      string = string + "\n"
    end
    string.gsub(/\s+/, "\n").lines
  end

  def commit_full_form_to_short_form(array)
    s = array.join.gsub(/\s+/, " ")
    s = s + "\\" if s.end_with?(" ")
    s
  end

  def new_commit_from_short_form(g, short_form_content, filename: "my_file.txt", commit_msg: nil)
    commit_msg ||= "Commit ##{g.log.size}"
    File.write("#{g.dir.path}/#{filename}", commit_short_form_to_full_form(short_form_content).join)
    g.add("my_file.txt")
    g.commit(commit_msg)
  end

  #
  # Below are just what is needed for the above method
  #

  SECTION_REGEX = /^###([^#].*)$/
  EXAMPLE_REGEX = /^####([^#].*)$/

  FixtureChunk = Struct.new(:name, :lines, :first_line_no) do
    def rechunk(pattern)
      self.class.chunk(lines, pattern, first_line_no)
    end

    def self.chunk(content, pattern, line_no = 1)
      all_lines = content.is_a?(String) ? content.lines : content
      chunks = all_lines.slice_before(pattern)
      chunks.map do |lines|
        if lines.first =~ pattern
          chunk_name = $1.strip
          lines = lines[1..-1]
          line_no += 1
        else
          chunk_name = 'Top'
        end
        next if lines.grep(/\S/).empty?
        chunk = FixtureChunk.new(chunk_name, lines, line_no)
        line_no += lines.size
        chunk
      end.compact
    end
  end

  def self.files
    Dir[__dir__ + '/../fixtures/**/*'].sort.map do |path|
      FixtureChunk.new(File.basename(path), File.read(path).lines, 1)
    end
  end

  class Fixture
    attr_reader :staged_file_before_execution, :commits_before_execution, :commits_after_execution, :options

    # The data is a multiline string that looks like this:
    #   d
    #   c d -> z c d
    #   b c d -> b z c d
    #   a b c d -> a b z c d
    #   a b z c d | {insert_checks: :below}
    #
    # * Each line but the last represents a commit
    # * The last line is not a commit, it's the state of the file when running auto-fixup
    # * Each letter represents a line in the commit.
    # * The -> indicate that after running auto-fixup, the commit will be modified into the right-side
    # * The | on the last line indicate options passed to auto-fixup
    def initialize(data)
      parse(data)
    end

    def parse(data)
      lines = data.is_a?(String) ? data.lines : data
      lines = lines.map { |l| l.gsub(/#.*/, '') }
      lines = lines.grep_v(/\A\s*\z/)

      final_line = lines.last
      final_commit, options = final_line.split('|', 2)
      @staged_file_before_execution = final_commit.strip
      @options = options ? eval(options) : {}

      commits = lines[0...-1].map do |line|
        before, after = line.split('->', 2).map(&:strip)
        after ||= before
        [before, after]
      end

      @commits_before_execution = commits.map(&:first)
      @commits_after_execution = commits.map(&:last)
    end
  end
end
