-- SebType: a word split by 个 (#484). Spoken Chinese splits verb–object words around 个: 健个身, 洗个澡,
-- 唱个歌. The dictionary has some of them (洗个澡) but not most (健个身), and librime's sentences, made
-- of dictionary words, don't split a word, so jiangeshen made 间隔神. When librime's first candidate is
-- such a sentence (no dictionary phrase reads the whole input) of 3 or 4 syllables and one inside it is
-- ge, this filter looks up the input without that ge as one dictionary phrase (jianshen: 健身) and puts
-- the phrase with 个 in its place (健个身) first. Longer inputs are sentences with a 个 of their own
-- (一个, 这个), which librime writes well. SebType's Chinese model then ranks it with the others, as
-- any of Rime's.
local M = {}

local LOOKUP = 3 -- the word translator's candidates read

function M.init(env)
  -- sebtype_word in the schema: rime_ice's dictionary, whole words only (no sentences, completions,
  -- corrections or learned words)
  env.word = Component.Translator(env.engine, "sebtype_word", "script_translator")
end

-- The word split by 个 for the sentence TOP, or nil.
local function split_word(env, top, input)
  local pieces, letters = {}, ""
  for p in top.preedit:gmatch("[^ ']+") do
    pieces[#pieces + 1] = p
    letters = letters .. p
  end
  if #pieces < 3 or #pieces > 4 or letters ~= input:sub(top.start + 1, top._end):gsub("'", "")
      or utf8.len(top.text) ~= #pieces then
    return nil
  end
  for i = 2, #pieces - 1 do
    if pieces[i] == "ge" then
      local x, y = table.concat(pieces, "", 1, i - 1), table.concat(pieces, "", i + 1)
      local seg = env.engine.context.composition:back()
      local t = env.word:query(x .. y, seg)
      if not t then return nil end
      local n = 0
      for c in t:iter() do
        n = n + 1
        if n > LOOKUP then break end
        if c._end - c.start == #x + #y and utf8.len(c.text) == #pieces - 1 and c:get_genuine().type == "phrase" then
          -- librime makes sentences even with enable_sentence off: only a dictionary phrase is a word
          local cut = utf8.offset(c.text, i)
          local made = Candidate("sebtype_ge", top.start, top._end, c.text:sub(1, cut - 1) .. "个" .. c.text:sub(cut), "")
          made.preedit = top.preedit
          return made
        end
      end
      return nil
    end
  end
  return nil
end

function M.func(input, env)
  local text = env.engine.context.input
  local first = true
  for cand in input:iter() do
    if first then
      first = false
      local made = cand:get_genuine().type == "sentence" and split_word(env, cand, text)
      if made and made.text ~= cand.text then yield(made) end
    end
    yield(cand)
  end
end

return M
