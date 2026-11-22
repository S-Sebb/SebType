-- SebType: candidates of the split the preedit shows come first (#485). For an input that splits more
-- than one way, librime lists the candidates of each prefix longest first: after jiangeshen's
-- sentences (jian ge shen) come every jiang character, rare ones included, and only then 健 and the
-- other jian ones. This filter keeps candidates that end where the first candidate's syllables end
-- (the split the preedit shows) in their order, and moves the others behind them, but for the first
-- few, so the other split stays in sight. Once candidates end before the first syllable's end, none of
-- the split shown can follow (librime lists longer ones first): the held ones come then, and the rest
-- pass.
local M = {}

local KEEP = 2 -- candidates of another split left in place
local LIMIT = 400 -- candidates held back at most: past that they come, and the rest pass

-- The input positions (byte offsets, as cand._end) where the syllables of cand's preedit end, and the
-- first of them; nil when it shows one syllable or doesn't spell the input letter for letter. The preedit shows a letter
-- for each one typed (ü for v), with a space or ' between syllables; a typed ' shows as one too.
local function boundaries(cand, input)
  local ends, pos, first = {}, cand.start, nil
  for _, c in utf8.codes(cand.preedit) do
    if c == 32 or c == 39 then
      first = first or pos
      ends[pos] = true
      if input:sub(pos + 1, pos + 1) == "'" then -- a candidate may end before or after it
        pos = pos + 1
        ends[pos] = true
      end
    else
      local typed = input:sub(pos + 1, pos + 1)
      if not typed:match("%a") then return nil end
      pos = pos + 1
    end
  end
  if not first or pos ~= cand._end then return nil end
  ends[pos] = true
  return ends, first
end

function M.func(input, env)
  local text = env.engine.context.input
  local ends, first, top
  local held, kept = {}, 0
  local function release()
    for _, cand in ipairs(held) do yield(cand) end
    held, ends = {}, nil
  end
  for cand in input:iter() do
    if not top then
      top = cand
      ends, first = boundaries(cand, text)
    elseif ends and cand.start == top.start and cand._end <= top._end and not ends[cand._end] then
      if cand._end < first or #held >= LIMIT then
        release()
      elseif kept < KEEP then
        kept = kept + 1
      else
        held[#held + 1] = cand
        cand = nil
      end
    end
    if cand then yield(cand) end
  end
  release()
end

return M
