# Time.parse for mruby — no Regexp dependency.
# Covers the formats actually emitted by GitHub API, RFC 3339 / ISO 8601,
# and plain "YYYY-MM-DD[ HH:MM:SS]".
#
# Returns a Time in UTC; add an offset yourself if you need local time.
# Raises ArgumentError on any unrecognized input (matches CRuby).

class Time
  def self.parse(str)
    s = str.to_s.strip
    raise ArgumentError, "Time.parse: empty string" if s.empty?

    n = s.length
    raise ArgumentError, "Time.parse: too short: #{str.inspect}" if n < 10
    unless _parse_digits?(s, 0, 4) && s[4] == "-" &&
           _parse_digits?(s, 5, 2) && s[7] == "-" &&
           _parse_digits?(s, 8, 2)
      raise ArgumentError, "Time.parse: bad date: #{str.inspect}"
    end

    year  = s[0, 4].to_i
    month = s[5, 2].to_i
    day   = s[8, 2].to_i

    return Time.utc(year, month, day, 0, 0, 0) if n == 10

    sep = s[10]
    unless sep == "T" || sep == "t" || sep == " "
      raise ArgumentError, "Time.parse: bad date/time separator: #{str.inspect}"
    end

    unless n >= 19 && _parse_digits?(s, 11, 2) && s[13] == ":" &&
           _parse_digits?(s, 14, 2) && s[16] == ":" &&
           _parse_digits?(s, 17, 2)
      raise ArgumentError, "Time.parse: bad time portion: #{str.inspect}"
    end

    hour = s[11, 2].to_i
    min  = s[14, 2].to_i
    sec  = s[17, 2].to_i

    pos = 19
    if pos < n && s[pos] == "."
      pos += 1
      start = pos
      pos += 1 while pos < n && s[pos] >= "0" && s[pos] <= "9"
      raise ArgumentError, "Time.parse: bad fractional seconds: #{str.inspect}" if pos == start
    end

    offset_seconds = pos < n ? _parse_tz_offset(s[pos..-1]) : 0
    Time.utc(year, month, day, hour, min, sec) - offset_seconds
  end

  # --- helpers (kept private-ish via underscore prefix) ---

  def self._parse_digits?(s, start, len)
    return false if start + len > s.length
    len.times do |i|
      c = s[start + i]
      return false unless c >= "0" && c <= "9"
    end
    true
  end

  def self._parse_tz_offset(tz)
    return 0 if tz == "Z" || tz == "z" || tz == "UTC" || tz == "GMT"

    len = tz.length
    unless len >= 3 && (tz[0] == "+" || tz[0] == "-")
      raise ArgumentError, "Time.parse: bad timezone: #{tz.inspect}"
    end
    sign = tz[0] == "-" ? -1 : 1

    # +HHMM / -HHMM
    if len == 5 && _parse_digits?(tz, 1, 2) && _parse_digits?(tz, 3, 2)
      return sign * (tz[1, 2].to_i * 3600 + tz[3, 2].to_i * 60)
    end

    # +HH:MM / -HH:MM
    if len == 6 && _parse_digits?(tz, 1, 2) && tz[3] == ":" && _parse_digits?(tz, 4, 2)
      return sign * (tz[1, 2].to_i * 3600 + tz[4, 2].to_i * 60)
    end

    # +HH / -HH
    if len == 3 && _parse_digits?(tz, 1, 2)
      return sign * tz[1, 2].to_i * 3600
    end

    raise ArgumentError, "Time.parse: bad timezone: #{tz.inspect}"
  end
end
