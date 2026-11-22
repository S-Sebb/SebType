-- SebType's Chinese model (core/src/chinese.cpp, #369) keeps a word the user taught Rime first, and ranks
-- the rest freely. Rime's C API doesn't say where a candidate comes from, so this filter, the last one,
-- puts Rime's first candidate's text in the context's property sebtype_learned when that candidate comes
-- from the user dictionary, and empties it otherwise. Likewise sebtype_sentence when the first is a sentence
-- librime pieced together from smaller entries, as sebtype_ge.lua tells them (#503: the model's misreadings
-- go back only behind a dictionary word). Only the first is looked at: it costs two calls a list.
local function filter(input, env)
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

return filter
