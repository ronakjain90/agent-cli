module Diff
  def self.unified(old_path, old_text, new_text, context: 3)
    old_lines = old_text.lines.map(&:chomp)
    new_lines = new_text.lines.map(&:chomp)

    return "" if old_lines == new_lines

    ses = compute_ses(old_lines, new_lines)
    format_unified(old_path, old_lines, new_lines, ses, context)
  end

  def self.compute_ses(a, b)
    m = a.length
    n = b.length
    dp = Array.new(m + 1) { Array.new(n + 1, 0) }
    (1..m).each { |i| (1..n).each { |j| dp[i][j] = a[i - 1] == b[j - 1] ? dp[i - 1][j - 1] + 1 : [dp[i - 1][j], dp[i][j - 1]].max } }

    ses = []
    i = m
    j = n
    while i > 0 || j > 0
      if i > 0 && j > 0 && a[i - 1] == b[j - 1]
        ses.unshift([:eq, i - 1, j - 1])
        i -= 1
        j -= 1
      elsif j > 0 && (i == 0 || dp[i][j - 1] >= dp[i - 1][j])
        ses.unshift([:ins, nil, j - 1])
        j -= 1
      else
        ses.unshift([:del, i - 1, nil])
        i -= 1
      end
    end
    ses
  end

  def self.format_unified(old_path, old_lines, new_lines, ses, context)
    return "" if ses.all? { |op, _, _| op == :eq }

    result = ["--- a/#{old_path}", "+++ b/#{old_path}"]

    changed_indices = ses.each_index.select { |i| ses[i][0] != :eq }
    return "" if changed_indices.empty?

    hunks = []
    i = 0
    while i < changed_indices.length
      hunk_start_cs = changed_indices[i]
      j = i
      while j + 1 < changed_indices.length && changed_indices[j + 1] - changed_indices[j] <= context * 2 + 1
        j += 1
      end
      hunk_end_ce = changed_indices[j]

      lo = [hunk_start_cs - context, 0].max
      hi = [hunk_end_ce + context, ses.length - 1].min

      hunks << [lo, hi]
      i = j + 1
    end

    hunks.each do |lo, hi|
      old_start = nil
      new_start = nil
      old_count = 0
      new_count = 0

      (lo..hi).each do |idx|
        op = ses[idx]
        case op[0]
        when :eq
          old_start ||= op[1] + 1
          new_start ||= op[2] + 1
          old_count += 1
          new_count += 1
        when :del
          old_start ||= op[1] + 1
          old_count += 1
        when :ins
          new_start ||= op[2] + 1
          new_count += 1
        end
      end

      result << "@@ -#{old_start},#{old_count} +#{new_start},#{new_count} @@"

      (lo..hi).each do |idx|
        op = ses[idx]
        case op[0]
        when :eq then result << " #{old_lines[op[1]]}"
        when :del then result << "-#{old_lines[op[1]]}"
        when :ins then result << "+#{new_lines[op[2]]}"
        end
      end
    end

    result.join("\n")
  end
end
