local appearance = require("factory-compression.appearance")
local compatibility = require("factory-compression.compatibility")
local config = require("factory-compression.config")
local energy = require("factory-compression.energy")
local recipe_categories = require("factory-compression.compat.recipe_categories")
local util = require("factory-compression.util")

local power = {}

local generated_kind_by_type = {
  ["solar-panel"] = "solar_panels",
  accumulator = "accumulators"
}

local function startup_value(name, fallback)
  local setting = settings.startup[name]
  if setting == nil then
    return fallback
  end
  return setting.value
end

local function collect_snapshot()
  local snapshot = {
    power_entities = {},
    recipes = {},
    technologies = {},
    technologies_by_name = {},
    recipe_unlocks = {},
    items = {},
    items_by_name = {}
  }

  for _, prototype_type in ipairs(config.supported_power_types) do
    local prototypes = data.raw[prototype_type] or {}
    for name, prototype in pairs(prototypes) do
      table.insert(snapshot.power_entities, {
        name = name,
        prototype_type = prototype_type,
        prototype = table.deepcopy(prototype)
      })
    end
  end

  for name, prototype in pairs(data.raw.recipe or {}) do
    table.insert(snapshot.recipes, {
      name = name,
      prototype = table.deepcopy(prototype)
    })
  end

  for name, prototype in pairs(data.raw.technology or {}) do
    local tech = table.deepcopy(prototype)
    table.insert(snapshot.technologies, {
      name = name,
      prototype = tech
    })
    snapshot.technologies_by_name[name] = tech

    for _, effect in ipairs(tech.effects or {}) do
      if effect.type == "unlock-recipe" and effect.recipe then
        snapshot.recipe_unlocks[effect.recipe] = snapshot.recipe_unlocks[effect.recipe] or {}
        table.insert(snapshot.recipe_unlocks[effect.recipe], name)
      end
    end
  end

  for _, prototype_type in ipairs(config.item_prototype_types) do
    for name, prototype in pairs(data.raw[prototype_type] or {}) do
      local item = {
        name = name,
        prototype_type = prototype_type,
        prototype = table.deepcopy(prototype)
      }
      table.insert(snapshot.items, item)
      snapshot.items_by_name[name] = item
    end
  end

  return snapshot
end

local function copy_unlock_techs(snapshot, recipe_name)
  local unlocks = {}
  for _, tech_name in ipairs(snapshot.recipe_unlocks[recipe_name] or {}) do
    local tech = snapshot.technologies_by_name[tech_name]
    if tech and not tech.hidden and tech.enabled ~= false then
      table.insert(unlocks, tech_name)
    end
  end
  return unlocks
end

local function product_name(product)
  if type(product) ~= "table" then
    return nil
  end
  if product.type ~= nil and product.type ~= "item" then
    return nil
  end
  return product.name or product[1]
end

local function recipe_produces_item(recipe, item_name)
  if recipe.result == item_name then
    return true
  end

  if type(recipe.results) == "table" then
    for _, product in ipairs(recipe.results) do
      if product_name(product) == item_name then
        return true
      end
    end
  end

  return false
end

local function recipe_item_results(recipe)
  local item_names = {}

  if recipe.result then
    table.insert(item_names, recipe.result)
  end

  if type(recipe.results) == "table" then
    for _, product in ipairs(recipe.results) do
      local name = product_name(product)
      if name then
        table.insert(item_names, name)
      end
    end
  end

  return item_names
end

function power.recipe_builds_supported_power_entity(snapshot, recipe)
  for _, item_name in ipairs(recipe_item_results(recipe)) do
    local item = util.find_item(snapshot, item_name)
    local entity_name = item and item.prototype.place_result

    if entity_name then
      for _, prototype_type in ipairs(config.supported_power_types) do
        if data.raw[prototype_type] and data.raw[prototype_type][entity_name] then
          return true
        end
      end
    end
  end

  return false
end

local function supported_power_item_names(snapshot)
  if snapshot.supported_power_item_names then
    return snapshot.supported_power_item_names
  end

  local names = {}

  for _, item in ipairs(snapshot.items or {}) do
    local entity_name = item.prototype.place_result
    if entity_name then
      for _, prototype_type in ipairs(config.supported_power_types) do
        if data.raw[prototype_type] and data.raw[prototype_type][entity_name] then
          names[item.name] = true
          break
        end
      end
    end
  end

  snapshot.supported_power_item_names = names
  return names
end

function power.recipe_is_supported_power_entity_related(snapshot, recipe_name, recipe)
  if power.recipe_builds_supported_power_entity(snapshot, recipe) then
    return true
  end

  local power_items = supported_power_item_names(snapshot)
  for item_name in pairs(power_items) do
    if recipe_name == item_name or recipe_name == item_name .. "-recycling" then
      return true
    end
  end

  return false
end

local function collect_source_prerequisites(snapshot, source_item_name)
  local prerequisites = {}

  for _, recipe in ipairs(snapshot.recipes) do
    if recipe_produces_item(recipe.prototype, source_item_name) then
      for _, tech_name in ipairs(copy_unlock_techs(snapshot, recipe.name)) do
        prerequisites[tech_name] = true
      end
    end
  end

  return prerequisites
end

local function require_electric_source(entity)
  if type(entity.energy_source) ~= "table" then
    return nil, "missing-energy-source"
  end

  if entity.energy_source.type ~= "electric" then
    return nil, "non-electric-energy-source"
  end

  return entity.energy_source
end

local function scale_required_energy_field(source, field, multiplier)
  if source[field] == nil then
    return nil, "missing-" .. field
  end

  local scaled, reason = util.multiply_energy(source[field], multiplier)
  if not scaled then
    return nil, "unsupported-" .. field, reason
  end

  return scaled
end

local function validate_solar_panel(entity, multiplier)
  local energy_source, reason = require_electric_source(entity)
  if not energy_source then
    return nil, reason
  end

  local production, detail = util.multiply_energy(entity.production, multiplier)
  if not production then
    return nil, "unsupported-production", detail
  end

  if energy_source.emissions_per_minute ~= nil and type(energy_source.emissions_per_minute) ~= "table" then
    return nil, "unsupported-emissions-per-minute", "not-a-table"
  end

  return {
    production = production
  }
end

local function validate_accumulator(entity, multiplier)
  local source, reason = require_electric_source(entity)
  if not source then
    return nil, reason
  end

  local scaled = {}
  local detail = nil

  scaled.buffer_capacity, reason, detail = scale_required_energy_field(source, "buffer_capacity", multiplier)
  if not scaled.buffer_capacity then
    return nil, reason, detail
  end

  scaled.input_flow_limit, reason, detail = scale_required_energy_field(source, "input_flow_limit", multiplier)
  if not scaled.input_flow_limit then
    return nil, reason, detail
  end

  scaled.output_flow_limit, reason, detail = scale_required_energy_field(source, "output_flow_limit", multiplier)
  if not scaled.output_flow_limit then
    return nil, reason, detail
  end

  if source.drain ~= nil then
    scaled.drain, detail = util.multiply_energy(source.drain, multiplier)
    if not scaled.drain then
      return nil, "unsupported-drain", detail
    end
  end

  if source.emissions_per_minute ~= nil and type(source.emissions_per_minute) ~= "table" then
    return nil, "unsupported-emissions-per-minute", "not-a-table"
  end

  return scaled
end

local function validate_power_entity(entry, multiplier)
  if entry.prototype_type == "solar-panel" then
    return validate_solar_panel(entry.prototype, multiplier)
  elseif entry.prototype_type == "accumulator" then
    return validate_accumulator(entry.prototype, multiplier)
  end

  return nil, "unsupported-power-type"
end

local function select_power_entities(snapshot, multiplier, logger)
  local selected = {}

  for _, entry in ipairs(snapshot.power_entities) do
    local blacklist_reason = compatibility.get_power_entity_blacklist_reason(entry.prototype_type, entry.name)
    local whitelisted = compatibility.is_power_entity_whitelisted(entry.prototype_type, entry.name)

    if util.starts_with(entry.name, config.generated_prefix) then
      logger:exclude("power_entities", entry.name, "generated-prefix", nil, false)
    elseif blacklist_reason and not whitelisted then
      logger:exclude("power_entities", entry.name, blacklist_reason, nil, true)
    elseif entry.prototype.next_upgrade and not whitelisted then
      logger:exclude("power_entities", entry.name, "has-next-upgrade", entry.prototype.next_upgrade, false)
    else
      local scaled, reason, detail = validate_power_entity(entry, multiplier)
      if not scaled then
        logger:exclude("power_entities", entry.name, reason, detail, true)
      else
        local source_item = util.find_source_item(snapshot, entry.prototype)
        if not source_item then
          logger:exclude("power_entities", entry.name, "source-item-not-found", nil, true)
        else
          table.insert(selected, {
            source = entry,
            source_item = source_item,
            scaled = scaled
          })
        end
      end
    end
  end

  return selected
end

local function update_minable(entity, item_name)
  if type(entity.minable) ~= "table" then
    return
  end

  entity.minable.result = item_name
  entity.minable.count = entity.minable.count or 1
  entity.minable.results = nil
end

local function apply_scaled_energy_source(entity, selected, multiplier)
  if selected.source.prototype_type == "accumulator" then
    entity.energy_source.buffer_capacity = selected.scaled.buffer_capacity
    entity.energy_source.input_flow_limit = selected.scaled.input_flow_limit
    entity.energy_source.output_flow_limit = selected.scaled.output_flow_limit

    if selected.scaled.drain then
      entity.energy_source.drain = selected.scaled.drain
    end
  end

  local ok, reason, detail = energy.scale_emissions_per_minute(entity.energy_source.emissions_per_minute, multiplier)
  if not ok then
    return false, reason, detail
  end

  return true
end

local function build_power_entity(selected, multiplier)
  local source = selected.source.prototype
  local entity = table.deepcopy(source)
  local generated_name = util.generated_entity_name(selected.source.name)

  entity.name = generated_name
  entity.localised_name = {"entity-name.factory-compression-ups-entity", source.name}
  entity.localised_description = {"entity-description.factory-compression-ups-entity"}
  entity.placeable_by = {item = generated_name, count = 1}

  if selected.source.prototype_type == "solar-panel" then
    entity.production = selected.scaled.production
  end

  local ok, reason, detail = apply_scaled_energy_source(entity, selected, multiplier)
  if not ok then
    return nil, reason, detail
  end

  update_minable(entity, generated_name)
  if not appearance.apply_icon_overlay(entity, source) then
    appearance.apply_icon_overlay(entity, selected.source_item.prototype)
  end

  return entity, appearance.apply_power_entity_tint(entity)
end

local function build_power_item(selected)
  local source_item = selected.source_item.prototype
  local item = table.deepcopy(source_item)
  local generated_name = util.generated_entity_name(selected.source.name)

  item.name = generated_name
  item.place_result = generated_name
  item.localised_name = {"item-name.factory-compression-ups-item", selected.source.name}
  item.localised_description = {"item-description.factory-compression-ups-item"}
  appearance.apply_icon_overlay(item, source_item)

  if item.order then
    item.order = item.order .. "-z[factory-compression]"
  end

  return item
end

local function add_ingredient(ingredients, name, amount)
  if amount > 0 and util.item_exists(name) then
    table.insert(ingredients, {type = "item", name = name, amount = amount})
    return true
  end

  return false
end

local function build_power_recipe(selected, multiplier)
  local generated_name = util.generated_entity_name(selected.source.name)
  local ingredients = {
    {type = "item", name = selected.source_item.name, amount = multiplier}
  }

  add_ingredient(ingredients, "speed-module-3", startup_value("factory-compression-speed-module-3-count", 5))
  add_ingredient(ingredients, "productivity-module-3", startup_value("factory-compression-productivity-module-3-count", 5))
  add_ingredient(ingredients, "efficiency-module-3", startup_value("factory-compression-efficiency-module-3-count", 5))

  local recipe = {
    type = "recipe",
    name = generated_name,
    localised_name = {"recipe-name.factory-compression-ups-power-recipe", selected.source.name},
    enabled = false,
    ingredients = ingredients,
    results = {{type = "item", name = generated_name, amount = 1}},
    auto_recycle = false,
    order = "z[factory-compression-power]-" .. selected.source.name
  }

  recipe_categories.set(recipe, {"crafting"})
  appearance.apply_icon_overlay(recipe, selected.source_item.prototype)

  return recipe
end

local function generate_power_entities(selected_entities, multiplier, logger)
  local prototypes = {}
  local unlock_recipe_names = {}

  for _, selected in ipairs(selected_entities) do
    local generated_name = util.generated_entity_name(selected.source.name)

    if data.raw[selected.source.prototype_type][generated_name] then
      logger:exclude("power_entities", selected.source.name, "generated-entity-already-exists", generated_name, true)
    elseif data.raw[selected.source_item.prototype_type][generated_name] then
      logger:exclude("power_entities", selected.source.name, "generated-item-already-exists", generated_name, true)
    elseif data.raw.recipe[generated_name] then
      logger:exclude("power_entities", selected.source.name, "generated-equipment-recipe-already-exists", generated_name, true)
    else
      local entity, tinted_layers_or_reason, detail = build_power_entity(selected, multiplier)
      if not entity then
        logger:exclude("power_entities", selected.source.name, tinted_layers_or_reason, detail, true)
      else
        local item = build_power_item(selected)
        local recipe = build_power_recipe(selected, multiplier)

        table.insert(prototypes, entity)
        table.insert(prototypes, item)
        table.insert(prototypes, recipe)
        table.insert(unlock_recipe_names, recipe.name)

        logger:generated_prototype(generated_kind_by_type[selected.source.prototype_type], entity.name)
        logger:generated_prototype("items", item.name)
        logger:generated_prototype("equipment_recipes", recipe.name)
        logger:appearance_result(entity.name, tinted_layers_or_reason, "no-safe-animation-layer")
      end
    end
  end

  return prototypes, unlock_recipe_names
end

local function add_default_power_prerequisites(prerequisites)
  for _, tech_name in ipairs({"production-science-pack", "utility-science-pack"}) do
    if data.raw.technology[tech_name] then
      prerequisites[tech_name] = true
    end
  end
end

local function science_pack_ingredients()
  local ingredients = {}
  for _, name in ipairs({
    "automation-science-pack",
    "logistic-science-pack",
    "chemical-science-pack",
    "production-science-pack",
    "utility-science-pack"
  }) do
    if util.item_exists(name) then
      table.insert(ingredients, {name, 1})
    end
  end
  return ingredients
end

local function build_technology(unlock_recipe_names, prerequisites)
  if #unlock_recipe_names == 0 then
    return nil, "no-unlock-recipes"
  end

  local ingredients = science_pack_ingredients()
  if #ingredients == 0 then
    return nil, "no-science-packs"
  end

  local effects = {}
  table.sort(unlock_recipe_names)
  for _, recipe_name in ipairs(unlock_recipe_names) do
    table.insert(effects, {
      type = "unlock-recipe",
      recipe = recipe_name
    })
  end

  local technology = {
    type = "technology",
    name = config.power_technology_name,
    icon = "__base__/graphics/technology/electric-energy-acumulators.png",
    icon_size = 256,
    prerequisites = util.set_to_sorted_array(prerequisites),
    effects = effects,
    unit = {
      count = 1000,
      ingredients = ingredients,
      time = 60
    },
    order = "z[factory-compression]-b[ups-power]"
  }

  appearance.apply_icon_overlay(technology)

  return technology
end

function power.run(multiplier, logger)
  local snapshot = collect_snapshot()
  local selected_entities = select_power_entities(snapshot, multiplier, logger)
  local prototypes, unlock_recipe_names = generate_power_entities(selected_entities, multiplier, logger)

  if #prototypes > 0 then
    data:extend(prototypes)
  end

  local prerequisites = {}
  add_default_power_prerequisites(prerequisites)
  for _, selected in ipairs(selected_entities) do
    local source_prerequisites = collect_source_prerequisites(snapshot, selected.source_item.name)
    for tech_name in pairs(source_prerequisites) do
      prerequisites[tech_name] = true
    end
  end

  if data.raw.technology[config.power_technology_name] then
    logger:exclude("errors", config.power_technology_name, "technology-already-exists", nil, true)
  else
    local technology, reason = build_technology(unlock_recipe_names, prerequisites)
    if technology then
      data:extend({technology})
      logger:generated_prototype("technologies", technology.name)
    elseif #unlock_recipe_names > 0 then
      logger:exclude("errors", config.power_technology_name, reason, nil, true)
    end
  end
end

return power
