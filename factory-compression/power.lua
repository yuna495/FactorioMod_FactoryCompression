local appearance = require("factory-compression.appearance")
local compatibility = require("factory-compression.compatibility")
local config = require("factory-compression.config")
local energy = require("factory-compression.energy")
local recipe_categories = require("factory-compression.compat.recipe_categories")
local util = require("factory-compression.util")

local power = {}

local generated_kind_by_type = {
  ["solar-panel"] = "solar_panels",
  accumulator = "accumulators",
  boiler = "boilers",
  generator = "generators"
}

local boiler_energy_source_types = {
  burner = true,
  heat = true
}

local reactor_neighbour_heat_bonus_multiplier = 1.2

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

local function scale_required_heat_buffer_field(heat_buffer, field, multiplier)
  if heat_buffer[field] == nil then
    return nil, "missing-heat-buffer-" .. field
  end

  local scaled, reason = util.multiply_energy(heat_buffer[field], multiplier)
  if not scaled then
    return nil, "unsupported-heat-buffer-" .. field, reason
  end

  return scaled
end

local function validate_heat_buffer(entity, specific_heat_multiplier, max_transfer_multiplier)
  if type(entity.heat_buffer) ~= "table" then
    return nil, "missing-heat-buffer"
  end

  local specific_heat, reason, detail = scale_required_heat_buffer_field(
    entity.heat_buffer,
    "specific_heat",
    specific_heat_multiplier
  )
  if not specific_heat then
    return nil, reason, detail
  end

  local max_transfer
  max_transfer, reason, detail = scale_required_heat_buffer_field(
    entity.heat_buffer,
    "max_transfer",
    max_transfer_multiplier
  )
  if not max_transfer then
    return nil, reason, detail
  end

  return {
    specific_heat = specific_heat,
    max_transfer = max_transfer
  }
end

local function validate_required_fluid_box(entity, field)
  local fluid_box = entity[field]
  if type(fluid_box) ~= "table" then
    return nil, "missing-" .. field
  end

  if type(fluid_box.volume) ~= "number" then
    return nil, "missing-" .. field .. "-volume"
  end

  return true
end

local function validate_optional_fluid_box(entity, field)
  if entity[field] == nil then
    return true
  end

  return validate_required_fluid_box(entity, field)
end

local function validate_indexed_fluid_boxes(entity)
  if entity.fluid_boxes == nil then
    return true
  end

  if type(entity.fluid_boxes) ~= "table" then
    return nil, "unsupported-fluid_boxes", "not-a-table"
  end

  for key, fluid_box in pairs(entity.fluid_boxes) do
    if type(fluid_box) ~= "table" then
      return nil, "unsupported-fluid_boxes", tostring(key)
    end
    if type(fluid_box.volume) ~= "number" then
      return nil, "missing-fluid_boxes-volume", tostring(key)
    end
  end

  return true
end

local function scale_fluid_box_volume(fluid_box, multiplier)
  if type(fluid_box) == "table" and type(fluid_box.volume) == "number" then
    fluid_box.volume = fluid_box.volume * multiplier
  end
end

local function scale_power_fluid_boxes(entity, multiplier)
  scale_fluid_box_volume(entity.fluid_box, multiplier)
  scale_fluid_box_volume(entity.input_fluid_box, multiplier)
  scale_fluid_box_volume(entity.output_fluid_box, multiplier)

  if type(entity.fluid_boxes) == "table" then
    for _, fluid_box in pairs(entity.fluid_boxes) do
      scale_fluid_box_volume(fluid_box, multiplier)
    end
  end
end

local function validate_boiler_energy_source(entity)
  if type(entity.energy_source) ~= "table" then
    return nil, "missing-energy-source"
  end

  local source_type = entity.energy_source.type
  if not boiler_energy_source_types[source_type] then
    return nil, "unsupported-boiler-energy-source", tostring(source_type)
  end

  return entity.energy_source
end

local function validate_energy_source(source, multiplier, include_drain)
  local copy = table.deepcopy(source)

  if include_drain then
    return energy.scale_energy_source(copy, multiplier)
  end

  return energy.scale_emissions_per_minute(copy.emissions_per_minute, multiplier)
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

local function validate_boiler(entity, multiplier)
  local source, reason, detail = validate_boiler_energy_source(entity)
  if not source then
    return nil, reason, detail
  end

  if type(entity.target_temperature) ~= "number" then
    return nil, "missing-target-temperature"
  end

  local energy_consumption
  energy_consumption, detail = util.multiply_energy(entity.energy_consumption, multiplier)
  if not energy_consumption then
    return nil, "unsupported-energy-consumption", detail
  end

  local ok
  ok, reason, detail = validate_required_fluid_box(entity, "fluid_box")
  if not ok then
    return nil, reason, detail
  end

  ok, reason, detail = validate_optional_fluid_box(entity, "input_fluid_box")
  if not ok then
    return nil, reason, detail
  end

  ok, reason, detail = validate_required_fluid_box(entity, "output_fluid_box")
  if not ok then
    return nil, reason, detail
  end

  ok, reason, detail = validate_indexed_fluid_boxes(entity)
  if not ok then
    return nil, reason, detail
  end

  ok, reason, detail = validate_energy_source(source, multiplier, true)
  if not ok then
    return nil, reason, detail
  end

  return {
    energy_consumption = energy_consumption
  }
end

local function validate_generator(entity, multiplier)
  local source, reason = require_electric_source(entity)
  if not source then
    return nil, reason
  end

  if type(entity.fluid_usage_per_tick) ~= "number" then
    return nil, "missing-fluid-usage-per-tick"
  end

  if entity.fluid_usage_per_tick <= 0 then
    return nil, "non-positive-fluid-usage-per-tick"
  end

  local ok, detail
  ok, reason, detail = validate_required_fluid_box(entity, "fluid_box")
  if not ok then
    return nil, reason, detail
  end

  ok, reason, detail = validate_indexed_fluid_boxes(entity)
  if not ok then
    return nil, reason, detail
  end

  local scaled = {
    fluid_usage_per_tick = entity.fluid_usage_per_tick * multiplier
  }

  if entity.max_power_output ~= nil then
    scaled.max_power_output, detail = util.multiply_energy(entity.max_power_output, multiplier)
    if not scaled.max_power_output then
      return nil, "unsupported-max-power-output", detail
    end
  end

  ok, reason, detail = validate_energy_source(source, multiplier, false)
  if not ok then
    return nil, reason, detail
  end

  return scaled
end

local function reactor_neighbour_bonus(entity)
  if entity.neighbour_bonus == nil then
    return 0
  end

  if type(entity.neighbour_bonus) ~= "number" then
    return nil, "unsupported-neighbour-bonus"
  end

  return entity.neighbour_bonus
end

local function validate_reactor(entity, multiplier)
  if type(entity.energy_source) ~= "table" then
    return nil, "missing-energy-source"
  end

  if entity.energy_source.type ~= "burner" then
    return nil, "unsupported-reactor-energy-source", tostring(entity.energy_source.type)
  end

  local neighbour_bonus, reason = reactor_neighbour_bonus(entity)
  if neighbour_bonus == nil then
    return nil, reason
  end

  local has_neighbour_bonus = neighbour_bonus > 0
  if has_neighbour_bonus and type(entity.energy_source.effectivity) ~= "number" then
    return nil, "missing-reactor-energy-source-effectivity"
  end

  local consumption, detail = util.multiply_energy(entity.consumption, multiplier)
  if not consumption then
    return nil, "unsupported-consumption", detail
  end

  local max_transfer_multiplier = multiplier
  if has_neighbour_bonus then
    max_transfer_multiplier = multiplier * reactor_neighbour_heat_bonus_multiplier
  end

  local heat_buffer
  heat_buffer, reason, detail = validate_heat_buffer(entity, multiplier, max_transfer_multiplier)
  if not heat_buffer then
    return nil, reason, detail
  end

  local ok
  ok, reason, detail = validate_energy_source(entity.energy_source, multiplier, false)
  if not ok then
    return nil, reason, detail
  end

  local scaled = {
    kind = has_neighbour_bonus and "reactors" or "heating_towers",
    consumption = consumption,
    heat_buffer = heat_buffer
  }

  if has_neighbour_bonus then
    scaled.effectivity = entity.energy_source.effectivity * reactor_neighbour_heat_bonus_multiplier
  end

  return scaled
end

local function validate_power_entity(entry, multiplier)
  if entry.prototype_type == "solar-panel" then
    return validate_solar_panel(entry.prototype, multiplier)
  elseif entry.prototype_type == "accumulator" then
    return validate_accumulator(entry.prototype, multiplier)
  elseif entry.prototype_type == "boiler" then
    return validate_boiler(entry.prototype, multiplier)
  elseif entry.prototype_type == "generator" then
    return validate_generator(entry.prototype, multiplier)
  elseif entry.prototype_type == "reactor" then
    return validate_reactor(entry.prototype, multiplier)
  end

  return nil, "unsupported-power-type"
end

local function fluid_filter(fluid_box)
  if type(fluid_box) ~= "table" then
    return nil
  end

  return fluid_box.filter
end

local function filters_match(output_filter, input_filter)
  return output_filter == nil or input_filter == nil or output_filter == input_filter
end

local function generator_minimum_temperature(generator)
  if type(generator.fluid_box) == "table" and type(generator.fluid_box.minimum_temperature) == "number" then
    return generator.fluid_box.minimum_temperature
  end

  if type(generator.minimum_temperature) == "number" then
    return generator.minimum_temperature
  end

  return nil
end

local function generator_maximum_temperature(generator)
  if type(generator.maximum_temperature) == "number" then
    return generator.maximum_temperature
  end

  if type(generator.fluid_box) == "table" and type(generator.fluid_box.maximum_temperature) == "number" then
    return generator.fluid_box.maximum_temperature
  end

  return nil
end

local function boiler_can_supply_generator(boiler, generator)
  if not filters_match(fluid_filter(boiler.output_fluid_box), fluid_filter(generator.fluid_box)) then
    return false
  end

  local target_temperature = boiler.target_temperature
  if type(target_temperature) ~= "number" then
    return false
  end

  local minimum_temperature = generator_minimum_temperature(generator)
  if minimum_temperature and target_temperature < minimum_temperature then
    return false
  end

  local maximum_temperature = generator_maximum_temperature(generator)
  if maximum_temperature and target_temperature > maximum_temperature then
    return false
  end

  return true
end

local function keep_boiler_generator_pairs(selected, logger)
  local boilers = {}
  local generators = {}

  for _, entry in ipairs(selected) do
    if entry.source.prototype_type == "boiler" then
      table.insert(boilers, entry)
    elseif entry.source.prototype_type == "generator" then
      table.insert(generators, entry)
    end
  end

  if #boilers == 0 and #generators == 0 then
    return selected
  end

  local paired_boilers = {}
  local paired_generators = {}

  for _, boiler in ipairs(boilers) do
    for _, generator in ipairs(generators) do
      if boiler_can_supply_generator(boiler.source.prototype, generator.source.prototype) then
        paired_boilers[boiler.source.name] = true
        paired_generators[generator.source.name] = true
      end
    end
  end

  local filtered = {}
  for _, entry in ipairs(selected) do
    if entry.source.prototype_type == "boiler" and not paired_boilers[entry.source.name] then
      logger:exclude("power_entities", entry.source.name, "no-compatible-generator", nil, true)
    elseif entry.source.prototype_type == "generator" and not paired_generators[entry.source.name] then
      logger:exclude("power_entities", entry.source.name, "no-compatible-boiler", nil, true)
    else
      table.insert(filtered, entry)
    end
  end

  return filtered
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

  return keep_boiler_generator_pairs(selected, logger)
end

local function update_minable(entity, item_name)
  if type(entity.minable) ~= "table" then
    return
  end

  entity.minable.result = item_name
  entity.minable.count = entity.minable.count or 1
  entity.minable.results = nil
end

local function apply_scaled_heat_buffer(entity, scaled)
  entity.heat_buffer.specific_heat = scaled.heat_buffer.specific_heat
  entity.heat_buffer.max_transfer = scaled.heat_buffer.max_transfer
end

local function apply_scaled_energy_source(entity, selected, multiplier)
  if selected.source.prototype_type == "accumulator" then
    entity.energy_source.buffer_capacity = selected.scaled.buffer_capacity
    entity.energy_source.input_flow_limit = selected.scaled.input_flow_limit
    entity.energy_source.output_flow_limit = selected.scaled.output_flow_limit

    if selected.scaled.drain then
      entity.energy_source.drain = selected.scaled.drain
    end

    local ok, reason, detail = energy.scale_emissions_per_minute(entity.energy_source.emissions_per_minute, multiplier)
    if not ok then
      return false, reason, detail
    end

    return true
  end

  if selected.source.prototype_type == "boiler" then
    return energy.scale_energy_source(entity.energy_source, multiplier)
  end

  if selected.source.prototype_type == "reactor" then
    return energy.scale_emissions_per_minute(entity.energy_source.emissions_per_minute, multiplier)
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
  elseif selected.source.prototype_type == "boiler" then
    entity.energy_consumption = selected.scaled.energy_consumption
    scale_power_fluid_boxes(entity, multiplier)
  elseif selected.source.prototype_type == "generator" then
    entity.fluid_usage_per_tick = selected.scaled.fluid_usage_per_tick
    if selected.scaled.max_power_output ~= nil then
      entity.max_power_output = selected.scaled.max_power_output
    end
    scale_power_fluid_boxes(entity, multiplier)
  elseif selected.source.prototype_type == "reactor" then
    entity.consumption = selected.scaled.consumption
    apply_scaled_heat_buffer(entity, selected.scaled)
    if selected.scaled.effectivity ~= nil then
      entity.energy_source.effectivity = selected.scaled.effectivity
    end
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

local function build_default_power_ingredients(selected, multiplier)
  local ingredients = {
    {type = "item", name = selected.source_item.name, amount = multiplier}
  }

  add_ingredient(ingredients, "speed-module-3", startup_value("factory-compression-speed-module-3-count", 5))
  add_ingredient(ingredients, "productivity-module-3", startup_value("factory-compression-productivity-module-3-count", 5))
  add_ingredient(ingredients, "efficiency-module-3", startup_value("factory-compression-efficiency-module-3-count", 5))

  return ingredients
end

local function build_power_ingredients(selected, multiplier)
  local override = compatibility.get_power_ingredient_override(selected.source.prototype_type, selected.source.name)
  if type(override) == "table" then
    return table.deepcopy(override)
  end

  return build_default_power_ingredients(selected, multiplier)
end

local function build_power_recipe(selected, multiplier)
  local generated_name = util.generated_entity_name(selected.source.name)
  local ingredients = build_power_ingredients(selected, multiplier)

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

local function generated_kind_for(selected)
  return selected.scaled.kind or generated_kind_by_type[selected.source.prototype_type]
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

        logger:generated_prototype(generated_kind_for(selected), entity.name)
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
