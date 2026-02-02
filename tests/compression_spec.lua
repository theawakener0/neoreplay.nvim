local compressor = require('neoreplay.compressor')

-- Mock events
local events = {
  { timestamp = 1.0, buf = 1, lnum = 1, lastline = 1, before = "a", after = "ab" },
  { timestamp = 1.1, buf = 1, lnum = 1, lastline = 1, before = "ab", after = "abc" },
  { timestamp = 1.2, buf = 1, lnum = 1, lastline = 1, before = "abc", after = "abcd" },
  { timestamp = 2.0, buf = 1, kind = 'segment', label = 'Branch point @2' },
  -- Break by time
  { timestamp = 5.0, buf = 1, lnum = 1, lastline = 1, before = "abcd", after = "abcde" },
  -- Break by line
  { timestamp = 5.1, buf = 1, lnum = 2, lastline = 2, before = "", after = "new line" },
}

local compressed = compressor.compress(events)

-- Assertion helper
local function assert_eq(a, b, msg)
  if a ~= b then
    error(string.format("Assertion failed: %s ~= %s (%s)", tostring(a), tostring(b), msg or ""))
  end
end

assert_eq(#compressed, 4, "Should compress into 4 groups including segment")
assert_eq(compressed[1].after, "abcd", "First group should have final state of last event in group")
assert_eq(compressed[1].start_time, 1.0, "First group should start at 1.0")
assert_eq(compressed[1].end_time, 1.2, "First group should end at 1.2")
assert_eq(compressed[2].kind, 'segment', "Second group should be segment marker")
assert_eq(compressed[3].after, "abcde", "Third group should be separate due to time gap")
assert_eq(compressed[4].lnum, 2, "Fourth group should be separate due to line change")

print("Compression tests passed!")
