local config = require("factory-compression.config")
local util = require("factory-compression.util")

local technology = {}

local function active_science_pack_names()
  if mods["space-age"] then
    return config.space_age_science_packs
  end

  return config.base_science_packs
end

function technology.science_pack_ingredients()
  local ingredients = {}

  for _, name in ipairs(active_science_pack_names()) do
    if util.item_exists(name) then
      table.insert(ingredients, {name, 1})
    end
  end

  return ingredients
end

function technology.research_count(multiplier)
  return multiplier * config.science_pack_cost_per_multiplier
end

function technology.add_science_pack_prerequisites(prerequisites)
  for _, name in ipairs(active_science_pack_names()) do
    local tech = data.raw.technology and data.raw.technology[name]
    if tech and not tech.hidden and tech.enabled ~= false then
      prerequisites[name] = true
    end
  end
end

return technology
