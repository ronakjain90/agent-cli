# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/agent_cli/tools"

# The invariant throughout: a read never quietly hands back less than it claims.
class ReadFileTest < Minitest::Test
  def in_project(&block)
    Dir.mktmpdir { |dir| Dir.chdir(dir, &block) }
  end

  # Lines wide enough that a few thousand exceed the model budget.
  def write_lines(path, count)
    File.write(path, (1..count).map { |i| "line #{i} #{"x" * 40}\n" }.join)
  end

  def read(input)
    Tools.call("read_file", input)
  end

  def test_whole_file_within_budget_comes_back_complete_and_bare
    in_project do
      write_lines("app.rb", 200)
      summary, body = read("path" => "app.rb")

      assert_equal File.read("app.rb"), body, "a file under budget must not be altered"
      assert_equal "read app.rb", summary
      refute_includes body, "truncated"
    end
  end

  # The regression: a 50KB source file used to arrive cut at 4096 bytes.
  def test_fifty_kilobyte_file_is_not_truncated
    in_project do
      write_lines("big.rb", 1_000)
      assert_operator File.size("big.rb"), :>, 45_000

      _, body = read("path" => "big.rb")

      assert_equal File.read("big.rb"), body
      assert_includes body, "line 1000 "
    end
  end

  def test_range_read_returns_every_requested_line
    in_project do
      write_lines("app.rb", 600)
      _, body = read("path" => "app.rb", "start_line" => 200, "end_line" => 500)

      assert_equal "# app.rb lines 200-500 of 600\n", body.lines.first
      assert_equal 302, body.lines.length, "header plus 301 inclusive lines"
      assert_includes body, "line 200 "
      assert_includes body, "line 500 "
      refute_includes body, "line 501 "
    end
  end

  def test_oversized_read_stops_on_a_line_boundary_and_reports_where
    in_project do
      write_lines("huge.rb", 4_000)
      summary, body = read("path" => "huge.rb")

      assert_includes summary, "truncated"
      assert_operator body.bytesize, :<=, MAX_FILE_RESULT_BYTES

      last = body[/stopped at line (\d+)/, 1].to_i
      assert_operator last, :>, 0, "truncation must name the line it stopped at"
      assert_includes body, "start_line: #{last + 1}"
      assert_includes body, "line #{last} ", "the named line must actually be present"
      refute_includes body, "line #{last + 1} ", "and the next one must not be"
    end
  end

  def test_resuming_at_the_reported_line_continues_without_a_gap
    in_project do
      write_lines("huge.rb", 4_000)
      _, first = read("path" => "huge.rb")
      resume = first[/start_line: (\d+)/, 1].to_i

      _, second = read("path" => "huge.rb", "start_line" => resume)

      assert_equal "line #{resume} #{"x" * 40}\n", second.lines[1], "must resume exactly where it left off"
    end
  end

  def test_following_resume_hints_reconstructs_the_whole_file
    in_project do
      write_lines("huge.rb", 4_000)
      collected = []
      cursor = 1

      12.times do
        _, body = read("path" => "huge.rb", "start_line" => cursor)
        lines = body.lines
        lines.shift # header
        hint = body[/start_line: (\d+)/, 1]
        lines.pop if hint # resume footer
        collected.concat(lines)
        break unless hint

        cursor = hint.to_i
      end

      assert_equal File.read("huge.rb"), collected.join
    end
  end

  def test_empty_file_reads_as_empty
    in_project do
      File.write("empty.rb", "")
      summary, body = read("path" => "empty.rb")

      assert_equal "read empty.rb", summary
      assert_equal "", body
    end
  end

  def test_out_of_range_start_is_reported_as_an_error
    in_project do
      write_lines("app.rb", 10)
      _, body = read("path" => "app.rb", "start_line" => 999)

      assert_includes body, "out of range"
      assert_includes body, "(10 lines)"
    end
  end

  def test_end_line_past_eof_clamps_to_the_last_line
    in_project do
      write_lines("app.rb", 10)
      _, body = read("path" => "app.rb", "start_line" => 8, "end_line" => 999)

      assert_equal "# app.rb lines 8-10 of 10\n", body.lines.first
      assert_includes body, "line 10 "
    end
  end

  def test_other_tools_keep_the_small_output_cap
    assert_equal MAX_MODEL_OUTPUT_BYTES, Tools.send(:cap_for, "run_command")
    assert_equal MAX_MODEL_OUTPUT_BYTES, Tools.send(:cap_for, "list_files")
    assert_equal MAX_FILE_RESULT_BYTES, Tools.send(:cap_for, "read_file")
  end
end
