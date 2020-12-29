require_relative "../spec_helper"

describe GitAutoFixup::Transformation do
  before(:all) do
    @root = Dir.mktmpdir("git_auto_fixup_test")
    @g = Git.init(@root)
  end

  after(:all) do
    FileUtils.remove_entry @root
  end

  let(:root) { @root }
  let(:g) { @g }

  def diff_lines(content1, content2)
    hash1, _status = Open3.capture2(*%W(git -C #{root} hash-object -w --stdin), stdin_data: commit_short_form_to_full_form(content1).join)
    hash2, _status = Open3.capture2(*%W(git -C #{root} hash-object -w --stdin), stdin_data: commit_short_form_to_full_form(content2).join)

    `git -C #{root} diff -U0 #{hash1.strip} #{hash2.strip}`.lines
  end

  def transformations(content1, content2)
    @raw_diff_lines = diff_lines(content1, content2)
    @ts = GitAutoFixup::Transformation.all_for_diff(nil, @raw_diff_lines, nil)
  end

  let(:ts) { @ts }
  let(:t) do
    ts.size.should == 1
    ts.first
  end

  it "modify first line" do
    transformations('a b c', 'z b c')
    [t.from_first_line_0i, t.from_nb_lines].should == [0, 1]
  end

  it "modify last line" do
    transformations('a b c', 'a b z')
    [t.from_first_line_0i, t.from_nb_lines].should == [2, 1]
  end

  it "insert first line" do
    transformations('a b c', 'z a b c')
    [t.from_first_line_0i, t.from_nb_lines].should == [0, 0]
  end

  it "insert last line" do
    transformations('a b c', 'a b c z')
    [t.from_first_line_0i, t.from_nb_lines].should == [3, 0]
  end

end
