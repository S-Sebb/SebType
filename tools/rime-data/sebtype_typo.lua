-- SebType's typo correction (#46): ranks the candidates of the correction translator (corr, librime's
-- correction on, its comments marked 〔…〕) by how likely the typo is on this keyboard. A correction's
-- score is its dictionary log weight with librime's flat correction penalty swapped for
-- log P(typed | intended) from a keyboard model: phone taps scatter as a Gaussian of 0.55 key widths
-- (Gboard's spatial model, Sivek & Riley 2022) on SebType's grid; a PC hits ANSI neighbour keys.
-- A correction never goes before an exact candidate that reads the input as full pinyin, or one that
-- covers more of the input; before any other exact candidate of the same length it goes when it is
-- more likely. Corrections that turn out exact are librime's own candidates again and are dropped.
--   sebtype_typo/keyboard: phone | pc     (pc set by the PC setup scripts)
local M = {}

local CORRECTION = -4.605170185988091 -- librime's credibility of a corrected syllable, log(0.01)
local ROWS = { "qwertyuiop", "asdfghjkl", "zxcvbnm" }
local BUFFER = 10 -- candidates re-ranked; after them only exact ones pass, as they come

-- Per-letter error rates: phone after Palin et al. 2019, PC after Dhakal et al. 2018.
local RATES = {
  phone = { sub = 0.021, omit = 0.0125, insert = 0.0042, swap = 0.0024 },
  pc = { sub = 0.0165, omit = 0.008, insert = 0.0067, swap = 0.002 },
}

-- sub[a][b] = -log P(b typed | a meant, a substitution happened)
local function substitution_costs(keyboard)
  local pos = {}
  for r, row in ipairs(ROWS) do
    for i = 1, #row do
      local x = keyboard == "pc" and (i - 1 + ({ 0, 0.25, 0.75 })[r]) or (i - 1 + ({ 0, 0.5, 1.5 })[r])
      -- phone keys are 108 x 160 px: rows are 1.48 key widths apart
      pos[row:sub(i, i)] = { x, (r - 1) * (keyboard == "pc" and 1 or 160 / 108) }
    end
  end
  local sub = {}
  for a, pa in pairs(pos) do
    local w, total = {}, 0
    for b, pb in pairs(pos) do
      if b ~= a then
        local d2 = (pa[1] - pb[1]) ^ 2 + (pa[2] - pb[2]) ^ 2
        if keyboard == "pc" then w[b] = d2 <= 1.25 ^ 2 and 1 or 1e-3
        else w[b] = math.exp(-d2 / (2 * 0.55 ^ 2)) + 1e-4 end
        total = total + w[b]
      end
    end
    sub[a] = {}
    for b, x in pairs(w) do sub[a][b] = -math.log(x / total) end
  end
  return sub
end

function M.init(env)
  local config = env.engine.schema.config
  local keyboard = config:get_string("sebtype_typo/keyboard") == "pc" and "pc" or "phone"
  local r = RATES[keyboard]
  env.sub = substitution_costs(keyboard)
  env.c_sub, env.c_omit = -math.log(r.sub), -math.log(r.omit)
  env.c_insert, env.c_swap = -math.log(r.insert), -math.log(r.swap)
end

-- -log P(typed | meant) for one syllable: weighted Damerau-Levenshtein from typed to any prefix of
-- meant (abbreviations and completions are librime's to price, as in its own matching).
local function syllable_cost(env, t, p)
  local m, n = #t, #p
  local d = {}
  for i = 0, m do
    d[i] = { [0] = i * env.c_insert }
  end
  for j = 1, n do d[0][j] = d[0][j - 1] + env.c_omit end
  for i = 1, m do
    local a = t:sub(i, i)
    for j = 1, n do
      local b = p:sub(j, j)
      local s = a == b and 0 or env.c_sub + ((env.sub[b] or {})[a] or 20)
      local v = math.min(d[i - 1][j - 1] + s, d[i - 1][j] + env.c_insert, d[i][j - 1] + env.c_omit)
      if i > 1 and j > 1 and a == p:sub(j - 1, j - 1) and b == t:sub(i - 1, i - 1) then
        v = math.min(v, d[i - 2][j - 2] + env.c_swap)
      end
      d[i][j] = v
    end
  end
  local best = math.huge
  for j = 1, n do best = math.min(best, d[m][j]) end
  return best
end

-- Log weight. A sentence's includes zh-moqi's grammar terms, which tell a real sentence from an
-- odd string of words; a sentence of one word takes that word's own weight, as the same phrase has.
local function weight(cand)
  local g = cand:get_genuine()
  local s = g.type == "sentence" and g:to_sentence()
  if s and #s.entrys == 1 then return s.entrys[1].weight end
  local p = g:to_phrase()
  return p and p.weight
end

-- For a corr candidate: its score, or nil when it is exact after all (or can't be read).
local function score(env, cand, input)
  local meant = cand.comment:match("^〔(.*)〕$")
  local w = weight(cand)
  if not meant or not w then return nil end
  local typed = input:sub(cand.start + 1, cand._end):gsub("'", "")
  local cost, pos, n = 0, 1, 0
  local parts = {}
  for s in meant:gmatch("%S+") do parts[#parts + 1] = s end
  local i = 0
  for t in cand.preedit:gmatch("[^ ']+") do
    i = i + 1
    local s, p = typed:sub(pos, pos + #t - 1), parts[i]
    pos = pos + #t
    if not p then return nil end
    if p:sub(1, #s) ~= s then
      if #s == 1 then return nil end -- a lone letter is an initial, abbreviating some word: not a typo
      cost = cost + syllable_cost(env, s, p)
      n = n + 1
    end
  end
  if i ~= #parts or pos ~= #typed + 1 or n == 0 then return nil end
  return w - n * CORRECTION - cost
end

-- Whether the input reads as this candidate's full pinyin, every syllable typed out, or as its
-- initials: then a typo is unlikely. Candidates without a spelling (a sentence over 8 syllables, English, custom phrases)
-- count as complete.
local function complete(cand)
  local meant = cand.comment:match("^［(.*)］$")
  if not meant or not cand.preedit:find("%a%a") then return true end -- initials only: an abbreviation
  -- the preedit shows ü as u or v (preedit_format), the spelling as the dictionary has it
  return meant:gsub("[v']", { v = "u", ["'"] = "" }) == cand.preedit:gsub("[v']", { v = "u", ["'"] = "" })
end

function M.func(input, env)
  local text = env.engine.context.input
  local exact, corr, seen = {}, {}, 0
  local function flush()
    table.sort(corr, function(a, b)
      if a.cand._end ~= b.cand._end then return a.cand._end > b.cand._end end
      return a.score > b.score
    end)
    local e, c = 1, 1
    while e <= #exact or c <= #corr do
      local x, y = exact[e], corr[c]
      local take_corr = y and (not x or y.cand._end > x._end)
      if y and x and not take_corr and y.cand._end == x._end then
        local w = not complete(x) and weight(x)
        take_corr = w and y.score > w
      end
      if take_corr then yield(y.cand); c = c + 1 else yield(x); e = e + 1 end
    end
  end
  for cand in input:iter() do
    seen = seen + 1
    local marked = cand.comment:find("^〔")
    if seen > BUFFER then
      if not marked then yield(cand) end
    elseif marked then
      local s = score(env, cand, text)
      if s then
        cand.comment = cand.comment:gsub("^〔(.*)〕$", "［%1］") -- as the main translator's, for corrector.lua
        corr[#corr + 1] = { cand = cand, score = s }
      end
    else
      exact[#exact + 1] = cand
    end
    if seen == BUFFER then flush() end
  end
  if seen < BUFFER then flush() end
end

return M
