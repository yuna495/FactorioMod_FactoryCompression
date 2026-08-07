local config = require("factory-compression.config")
local appearance = require("factory-compression.appearance")
local compatibility = require("factory-compression.compatibility")
local energy = require("factory-compression.energy")
local logger_module = require("factory-compression.logger")
local power = require("factory-compression.power")
local recipe_categories = require("factory-compression.compat.recipe_categories")
local util = require("factory-compression.util")

local generator = {}

local function startup_value(name, fallback)
  local setting = settings.startup[name]
  if setting == nil then
    return fallback
  end
  return setting.value
end

local function collect_snapshot()
  local snapshot = {
    machines = {},
    recipes = {},
    technologies = {},
    technologies_by_name = {},
    recipe_unlocks = {},
    items = {},
    items_by_name = {},
    fluids_by_name = {}
  }

  for _, prototype_type in ipairs(config.supported_machine_types) do
    local prototypes = data.raw[prototype_type] or {}
    for name, prototype in pairs(prototypes) do
      table.insert(snapshot.machines, {
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

  for name, prototype in pairs(data.raw.fluid or {}) do
    snapshot.fluids_by_name[name] = {
      name = name,
      prototype = table.deepcopy(prototype)
    }
  end

  return snapshot
end

local function scale_fluid_box_volume(fluid_box, multiplier)
  if type(fluid_box) == "table" and type(fluid_box.volume) == "number" then
    fluid_box.volume = fluid_box.volume * multiplier
  end
end

local function scale_machine_fluid_boxes(machine, multiplier)
  scale_fluid_box_volume(machine.fluid_box, multiplier)
  scale_fluid_box_volume(machine.input_fluid_box, multiplier)
  scale_fluid_box_volume(machine.output_fluid_box, multiplier)

  if type(machine.fluid_boxes) == "table" then
    for _, fluid_box in pairs(machine.fluid_boxes) do
      scale_fluid_box_volume(fluid_box, multiplier)
    end
  end
end

local function update_minable(machine, item_name)
  machine.minable = machine.minable or {mining_time = 0.2}
  machine.minable.result = item_name
  machine.minable.count = machine.minable.count or 1
  machine.minable.results = nil
end

local function has_supported_categories(machine)
  return type(machine.crafting_categories) == "table" and #machine.crafting_categories > 0
end

local function category_exists(category)
  return data.raw["recipe-category"] and data.raw["recipe-category"][category] ~= nil
end

local function select_machines(snapshot, multiplier, logger)
  local selected = {}

  for _, entry in ipairs(snapshot.machines) do
    local machine = entry.prototype
    local blacklist_reason = compatibility.get_machine_blacklist_reason(entry.prototype_type, entry.name)
    local whitelisted = compatibility.is_machine_whitelisted(entry.prototype_type, entry.name)

    if util.starts_with(entry.name, config.generated_prefix) then
      logger:exclude("machines", entry.name, "generated-prefix", nil, false)
    elseif blacklist_reason and not whitelisted then
      logger:exclude("machines", entry.name, blacklist_reason, nil, true)
    elseif machine.next_upgrade and not whitelisted then
      logger:exclude("machines", entry.name, "has-next-upgrade", machine.next_upgrade, false)
    elseif machine.fixed_recipe then
      logger:exclude("machines", entry.name, "fixed-recipe", machine.fixed_recipe, true)
    elseif not has_supported_categories(machine) then
      logger:exclude("machines", entry.name, "no-crafting-categories", nil, true)
    elseif not machine.energy_usage then
      logger:exclude("machines", entry.name, "missing-energy-usage", nil, true)
    else
      local scaled_energy_usage, energy_reason = energy.scale_energy_usage(machine.energy_usage, multiplier)
      if not scaled_energy_usage then
        logger:exclude("machines", entry.name, "unsupported-energy-usage", energy_reason, true)
      else
        local source_item = util.find_source_item(snapshot, machine)
        if not source_item then
          logger:exclude("machines", entry.name, "source-item-not-found", nil, true)
        else
          local missing_category = nil
          for _, category in ipairs(machine.crafting_categories) do
            if not category_exists(category) then
              missing_category = category
              break
            end
          end

          if missing_category then
            logger:exclude("machines", entry.name, "missing-recipe-category", missing_category, true)
          else
            logger:note("final_tier_candidates", 1)
            table.insert(selected, {
              source = entry,
              source_item = source_item,
              scaled_energy_usage = scaled_energy_usage
            })
          end
        end
      end
    end
  end

  return selected
end

local function create_recipe_categories(selected_machines, logger)
  local categories = {}
  local created = {}
  local category_map = {}

  for _, selected in ipairs(selected_machines) do
    for _, source_category in ipairs(selected.source.prototype.crafting_categories) do
      local generated_category = util.category_name(source_category)
      category_map[source_category] = generated_category

      if not data.raw["recipe-category"][generated_category] and not created[generated_category] then
        created[generated_category] = true
        table.insert(categories, {
          type = "recipe-category",
          name = generated_category
        })
        logger:generated_prototype("categories", generated_category)
      end
    end
  end

  if #categories > 0 then
    data:extend(categories)
  end

  return category_map
end

local function build_machine_entity(selected, category_map, multiplier)
  local source = selected.source.prototype
  local entity = table.deepcopy(source)
  local generated_name = util.generated_entity_name(selected.source.name)

  entity.name = generated_name
  entity.localised_name = {"entity-name.factory-compression-ups-entity", source.name}
  entity.localised_description = {"entity-description.factory-compression-ups-entity"}
  entity.energy_usage = selected.scaled_energy_usage
  entity.next_upgrade = nil
  entity.placeable_by = {item = generated_name, count = 1}

  entity.crafting_categories = {}
  for _, source_category in ipairs(source.crafting_categories) do
    table.insert(entity.crafting_categories, category_map[source_category])
  end

  local ok, reason, detail = energy.scale_energy_source(entity.energy_source, multiplier)
  if not ok then
    return nil, reason, detail
  end

  scale_machine_fluid_boxes(entity, multiplier)
  update_minable(entity, generated_name)
  if not appearance.apply_icon_overlay(entity, source) then
    appearance.apply_icon_overlay(entity, selected.source_item.prototype)
  end

  return entity, appearance.apply_entity_tint(entity)
end

local function build_machine_item(selected)
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

local function build_machine_recipe(selected, multiplier)
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
    localised_name = {"recipe-name.factory-compression-ups-machine-recipe", selected.source.name},
    enabled = false,
    ingredients = ingredients,
    results = {{type = "item", name = generated_name, amount = 1}},
    auto_recycle = false,
    order = "z[factory-compression]-" .. selected.source.name
  }

  recipe_categories.set(recipe, {"crafting"})
  appearance.apply_icon_overlay(recipe, selected.source_item.prototype)

  return recipe
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

local function scale_item_number(value, multiplier)
  local scaled = value * multiplier
  if scaled > config.item_amount_max then
    return nil
  end

  return scaled
end

local function ingredient_type(ingredient)
  return ingredient.type or "item"
end

local function is_non_stackable_item(snapshot, name)
  local item = snapshot.items_by_name[name]
  return item and (config.non_stackable_item_types[item.prototype_type] == true or item.prototype.stack_size == 1)
end

local function scale_ingredient(snapshot, ingredient, multiplier)
  local copy = table.deepcopy(ingredient)
  if copy.name == nil and copy[1] ~= nil then
    copy = {
      type = copy.type or "item",
      name = copy[1],
      amount = copy[2]
    }
  end

  local kind = ingredient_type(copy)

  if type(copy.amount) ~= "number" then
    return nil, "ingredient-missing-amount"
  end

  if kind == "item" then
    local scaled = scale_item_number(copy.amount, multiplier)
    if not scaled then
      return nil, "item-ingredient-amount-overflow"
    end
    if scaled > 1 and is_non_stackable_item(snapshot, copy.name) then
      return nil, "non-stackable-item-ingredient"
    end
    copy.amount = scaled

    if type(copy.ignored_by_stats) == "number" then
      local ignored = scale_item_number(copy.ignored_by_stats, multiplier)
      if not ignored then
        return nil, "item-ingredient-ignored-by-stats-overflow"
      end
      copy.ignored_by_stats = ignored
    end
  elseif kind == "fluid" then
    copy.amount = copy.amount * multiplier
    if type(copy.ignored_by_stats) == "number" then
      copy.ignored_by_stats = copy.ignored_by_stats * multiplier
    end
  else
    return nil, "unsupported-ingredient-type"
  end

  return copy
end

local function scale_item_product_number(value, multiplier)
  local scaled = value * multiplier
  if scaled > config.item_amount_max then
    return nil
  end
  return scaled
end

local function scale_product(snapshot, product, multiplier)
  local copy = table.deepcopy(product)
  if copy.name == nil and copy[1] ~= nil then
    copy = {
      type = copy.type or "item",
      name = copy[1],
      amount = copy[2]
    }
  end

  local kind = copy.type or "item"

  local function scale_field(field)
    if type(copy[field]) == "number" then
      if kind == "item" then
        local scaled = scale_item_product_number(copy[field], multiplier)
        if not scaled then
          return false, "item-product-" .. field .. "-overflow"
        end
        if scaled > 1 and is_non_stackable_item(snapshot, copy.name) then
          return false, "non-stackable-item-product"
        end
        copy[field] = scaled
      elseif kind == "fluid" then
        copy[field] = copy[field] * multiplier
      else
        return false, "unsupported-product-type"
      end
    end
    return true
  end

  for _, field in ipairs({"amount", "amount_min", "amount_max", "ignored_by_productivity", "ignored_by_stats"}) do
    local ok, reason = scale_field(field)
    if not ok then
      return nil, reason
    end
  end

  if kind == "item" and type(copy.extra_count_fraction) == "number" then
    if copy.amount == nil then
      return nil, "extra-count-fraction-without-fixed-amount"
    end

    local total_extra = copy.extra_count_fraction * multiplier
    local whole_extra = math.floor(total_extra)
    copy.extra_count_fraction = total_extra - whole_extra

    if whole_extra > 0 then
      local base_amount = copy.amount
      local new_amount = base_amount + whole_extra
      if new_amount > config.item_amount_max then
        return nil, "item-product-extra-count-overflow"
      end
      if new_amount > 1 and is_non_stackable_item(snapshot, copy.name) then
        return nil, "non-stackable-item-product"
      end
      copy.amount = new_amount
    end
  end

  return copy
end

local function scale_recipe_payload(snapshot, recipe, multiplier)
  local scaled_ingredients = {}
  for _, ingredient in ipairs(recipe.ingredients or {}) do
    local scaled, reason = scale_ingredient(snapshot, ingredient, multiplier)
    if not scaled then
      return nil, reason
    end
    table.insert(scaled_ingredients, scaled)
  end

  if type(recipe.results) ~= "table" or #recipe.results == 0 then
    return nil, "recipe-missing-results"
  end

  local scaled_results = {}
  for _, product in ipairs(recipe.results) do
    local scaled, reason = scale_product(snapshot, product, multiplier)
    if not scaled then
      return nil, reason
    end
    table.insert(scaled_results, scaled)
  end

  return {
    ingredients = scaled_ingredients,
    results = scaled_results
  }
end

local function category_overlap(source_categories, category_map)
  local mapped = {}
  local seen = {}
  for _, category in ipairs(source_categories) do
    local generated_category = category_map[category]
    if generated_category and not seen[generated_category] then
      seen[generated_category] = true
      table.insert(mapped, generated_category)
    end
  end
  return mapped
end

local function recipe_icon_source(snapshot, source_recipe)
  if source_recipe.icon or source_recipe.icons then
    return source_recipe
  end

  local product_name = source_recipe.main_product
  local product_type = nil
  if (not product_name or product_name == "") and type(source_recipe.results) == "table" and #source_recipe.results == 1 then
    local product = source_recipe.results[1]
    if type(product) == "table" then
      product_name = product.name or product[1]
      product_type = product.type
    end
  end

  if product_type == "fluid" then
    local fluid = snapshot.fluids_by_name[product_name]
    return fluid and fluid.prototype or nil
  end

  local item = util.find_item(snapshot, product_name)
  if item then
    return item.prototype
  end

  local fluid = snapshot.fluids_by_name[product_name]
  return fluid and fluid.prototype or nil
end

local function build_batch_recipe(snapshot, source_recipe, source_recipe_name, mapped_categories, scaled_payload, multiplier)
  local recipe = table.deepcopy(source_recipe)

  recipe.name = util.batch_recipe_name(source_recipe_name)
  recipe.localised_name = {
    "recipe-name.factory-compression-batch-recipe",
    source_recipe_name,
    tostring(multiplier)
  }
  recipe.enabled = false
  recipe.ingredients = scaled_payload.ingredients
  recipe.results = scaled_payload.results
  recipe.auto_recycle = false
  recipe.hidden = false
  recipe.hide_from_player_crafting = true
  recipe.hidden_in_factoriopedia = true

  if recipe.order then
    recipe.order = recipe.order .. "-z[factory-compression-batch]"
  end

  recipe_categories.set(recipe, mapped_categories)
  appearance.apply_icon_overlay(recipe, recipe_icon_source(snapshot, source_recipe))

  return recipe
end

local function generate_batch_recipes(snapshot, category_map, multiplier, logger)
  local generated = {}

  for _, entry in ipairs(snapshot.recipes) do
    local source_recipe = entry.prototype
    local blacklist_reason = compatibility.get_recipe_blacklist_reason(entry.name)

    if util.starts_with(entry.name, config.generated_prefix) then
      logger:exclude("recipes", entry.name, "generated-prefix", nil, false)
    elseif blacklist_reason and not compatibility.is_recipe_whitelisted(entry.name) then
      logger:exclude("recipes", entry.name, blacklist_reason, nil, true)
    elseif data.raw.recipe[util.batch_recipe_name(entry.name)] then
      logger:exclude("recipes", entry.name, "generated-recipe-already-exists", util.batch_recipe_name(entry.name), true)
    elseif source_recipe.normal or source_recipe.expensive then
      logger:exclude("recipes", entry.name, "difficulty-variant-recipe", nil, true)
    elseif power.recipe_is_supported_power_entity_related(snapshot, entry.name, source_recipe) then
      logger:exclude("recipes", entry.name, "power-equipment-recipe", nil, false)
    else
      local mapped_categories = category_overlap(recipe_categories.get(source_recipe), category_map)
      if #mapped_categories == 0 then
        logger:exclude("recipes", entry.name, "no-supported-category", nil, false)
      else
        local unlocks = copy_unlock_techs(snapshot, entry.name)
        if source_recipe.enabled == false and #unlocks == 0 then
          logger:exclude("recipes", entry.name, "disabled-source-recipe-without-visible-unlock", nil, false)
        else
          local scaled_payload, reason = scale_recipe_payload(snapshot, source_recipe, multiplier)
          if not scaled_payload then
            local always_log = reason ~= "non-stackable-item-ingredient" and reason ~= "non-stackable-item-product"
            logger:exclude("recipes", entry.name, reason, nil, always_log)
          else
            local batch_recipe = build_batch_recipe(snapshot, source_recipe, entry.name, mapped_categories, scaled_payload, multiplier)
            table.insert(generated, batch_recipe)
            logger:generated_prototype("batch_recipes", batch_recipe.name)
          end
        end
      end
    end
  end

  return generated
end

local function generate_machines(selected_machines, category_map, multiplier, logger)
  local prototypes = {}
  local unlock_recipe_names = {}

  for _, selected in ipairs(selected_machines) do
    local generated_name = util.generated_entity_name(selected.source.name)

    if data.raw[selected.source.prototype_type][generated_name] then
      logger:exclude("machines", selected.source.name, "generated-machine-already-exists", generated_name, true)
    elseif data.raw[selected.source_item.prototype_type][generated_name] then
      logger:exclude("machines", selected.source.name, "generated-item-already-exists", generated_name, true)
    elseif data.raw.recipe[generated_name] then
      logger:exclude("machines", selected.source.name, "generated-equipment-recipe-already-exists", generated_name, true)
    else
      local entity, tinted_layers_or_reason, detail = build_machine_entity(selected, category_map, multiplier)
      if not entity then
        logger:exclude("machines", selected.source.name, tinted_layers_or_reason, detail, true)
      else
        local item = build_machine_item(selected)
        local recipe = build_machine_recipe(selected, multiplier)

        table.insert(prototypes, entity)
        table.insert(prototypes, item)
        table.insert(prototypes, recipe)
        table.insert(unlock_recipe_names, recipe.name)

        logger:generated_prototype("machines", entity.name)
        logger:generated_prototype("items", item.name)
        logger:generated_prototype("equipment_recipes", recipe.name)
        logger:appearance_result(entity.name, tinted_layers_or_reason, "no-safe-animation-layer")
      end
    end
  end

  return prototypes, unlock_recipe_names
end

local function add_default_prerequisites(prerequisites)
  for _, tech_name in ipairs({"automation-3", "advanced-material-processing-2", "production-science-pack", "utility-science-pack"}) do
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
    name = config.technology_name,
    icon = "__base__/graphics/technology/automation-3.png",
    icon_size = 256,
    prerequisites = util.set_to_sorted_array(prerequisites),
    effects = effects,
    unit = {
      count = 1000,
      ingredients = ingredients,
      time = 60
    },
    order = "z[factory-compression]-a[ups-machines]"
  }

  appearance.apply_icon_overlay(technology)

  return technology
end

function generator.run()
  local multiplier = tonumber(startup_value("factory-compression-multiplier", "10")) or 10
  local detailed_logging = startup_value("factory-compression-detailed-logging", false) == true
  local logger = logger_module.new(detailed_logging)

  local snapshot = collect_snapshot()
  local selected_machines = select_machines(snapshot, multiplier, logger)
  local category_map = create_recipe_categories(selected_machines, logger)
  local machine_prototypes, machine_recipe_unlocks = generate_machines(selected_machines, category_map, multiplier, logger)
  local batch_recipes = generate_batch_recipes(snapshot, category_map, multiplier, logger)

  if #machine_prototypes > 0 then
    data:extend(machine_prototypes)
  end

  if #batch_recipes > 0 then
    data:extend(batch_recipes)
  end

  local unlock_recipe_names = {}
  for _, name in ipairs(machine_recipe_unlocks) do
    table.insert(unlock_recipe_names, name)
  end
  for _, recipe in ipairs(batch_recipes) do
    table.insert(unlock_recipe_names, recipe.name)
  end

  local prerequisites = {}
  add_default_prerequisites(prerequisites)

  if data.raw.technology[config.technology_name] then
    logger:exclude("errors", config.technology_name, "technology-already-exists", nil, true)
  else
    local technology, reason = build_technology(unlock_recipe_names, prerequisites)
    if technology then
      data:extend({technology})
      logger:generated_prototype("technologies", technology.name)
    else
      logger:exclude("errors", config.technology_name, reason, nil, true)
    end
  end

  power.run(multiplier, logger)

  logger:summary()
end

return generator
