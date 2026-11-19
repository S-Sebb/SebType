-- SebType's Chinese model (core/src/chinese.cpp, #369) keeps a word the user taught Rime first, and ranks
-- the rest freely. Rime's C API doesn't say where a candidate comes from, so this filter, the last one,
-- puts Rime's first candidate's text in the context's property sebtype_learned when that candidate comes
-- from the user dictionary, and empties it otherwise. Only the first is looked at: it costs one call a list.
local function filter(input, env)
  local first = true
  for cand in input:iter() do
    if first then
      first = false
      local t = cand:get_genuine().type
      env.engine.context:set_property("sebtype_learned", (t == "user_phrase" or t == "user_table") and cand.text or "")
    end
    yield(cand)
  end
end

return filter
