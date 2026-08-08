local config = require("factory-compression.config")

local unlock_data_names = {
  config.machine_unlock_data_name,
  config.power_unlock_data_name
}

local function starts_with(value, prefix)
  return type(value) == "string" and string.sub(value, 1, #prefix) == prefix
end

local function unlock_data(name)
  local prototype = prototypes.mod_data and prototypes.mod_data[name]
  return prototype and prototype.data or nil
end

local function technology_researched(force, technology_name)
  local technology = force.technologies[technology_name]
  return technology and technology.researched == true
end

local function source_recipe_unlocked(force, source_recipes)
  if type(source_recipes) ~= "table" then
    return false
  end

  for _, source_recipe_name in pairs(source_recipes) do
    local recipe = force.recipes[source_recipe_name]
    if recipe and recipe.enabled then
      return true
    end
  end

  return false
end

local function sync_unlock_data(force, data)
  if type(data) ~= "table" then
    return
  end

  local ups_technology_researched = technology_researched(force, data.technology)

  for recipe_name, metadata in pairs(data.recipes or {}) do
    local recipe = force.recipes[recipe_name]
    if recipe then
      recipe.enabled = ups_technology_researched and source_recipe_unlocked(force, metadata.source_recipes)
    end
  end
end

local function sync_force(force)
  for _, data_name in ipairs(unlock_data_names) do
    sync_unlock_data(force, unlock_data(data_name))
  end
end

local function sync_all_forces()
  for _, force in pairs(game.forces) do
    sync_force(force)
  end
end

script.on_init(sync_all_forces)
script.on_configuration_changed(sync_all_forces)

script.on_event(defines.events.on_research_finished, function(event)
  sync_force(event.research.force)
end)

script.on_event(defines.events.on_research_reversed, function(event)
  sync_force(event.research.force)
end)

script.on_event(defines.events.on_technology_effects_reset, function(event)
  sync_force(event.force)
end)

script.on_event(defines.events.on_force_created, function(event)
  sync_force(event.force)
end)

script.on_event(defines.events.on_force_reset, function(event)
  sync_force(event.force)
end)

script.on_event(defines.events.on_forces_merged, function(event)
  sync_force(event.destination)
end)

local function sync_if_generated_entity_was_built(event)
  local entity = event.entity or event.created_entity
  if entity and entity.valid and entity.force and starts_with(entity.name, config.ups_prefix) then
    sync_force(entity.force)
  end
end

script.on_event(defines.events.on_built_entity, sync_if_generated_entity_was_built)
script.on_event(defines.events.on_robot_built_entity, sync_if_generated_entity_was_built)
script.on_event(defines.events.script_raised_built, sync_if_generated_entity_was_built)
script.on_event(defines.events.script_raised_revive, sync_if_generated_entity_was_built)
