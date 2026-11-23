-- SebType's Chinese model (core/src/chinese.cpp, #369) keeps a word the user taught Rime first, and ranks
-- the rest freely. Rime's C API doesn't say where a candidate comes from, so this filter, the last one,
-- puts Rime's first candidate's text in the context's property sebtype_learned when that candidate comes
-- from the user dictionary, and empties it otherwise. Likewise sebtype_sentence when the first is a sentence
-- librime pieced together from smaller entries, as sebtype_ge.lua tells them (#503: the model's misreadings
-- go back only behind a dictionary word). Only the first is looked at: it costs two calls a list.
--
-- Nor can the C API write to the user dictionary: the model sets the property sebtype_learn to
-- "<syllables>\t<text>" ("mao gou ji ya\t猫狗就要") when the user picks one of its own guesses that Rime has
-- no pieces for (#518), and this puts it into the main translator's user dictionary under those syllables,
-- as Rime learns a pick. The Memory is made for each one and disconnected after it: a Memory kept would
-- also take every commit, which starts a new transaction and so ends Rime's undo of a commit by Backspace.
local M = {}

function M.init(env)
  env.learn = env.engine.context.property_update_notifier:connect(function(ctx, name)
    if name ~= "sebtype_learn" then return end
    local code, text = ctx:get_property(name):match("^(.-)\t(.+)$")
    if not code then return end
    local memory = Memory(env.engine, env.engine.schema)
    local entry = DictEntry()
    entry.text = text
    entry.custom_code = code .. " " -- as Rime's user dictionary keys its entries: "mao gou ji ya "
    memory:update_userdict(entry, 1, "")
    memory:finish_session()
    memory:disconnect()
  end)
end

function M.fini(env)
  env.learn:disconnect()
end

function M.func(input, env)
  local first = true
  for cand in input:iter() do
    if first then
      first = false
      local t = cand:get_genuine().type
      env.engine.context:set_property("sebtype_learned", (t == "user_phrase" or t == "user_table") and cand.text or "")
      env.engine.context:set_property("sebtype_sentence", t == "sentence" and cand.text or "")
    end
    yield(cand)
  end
end

return M
