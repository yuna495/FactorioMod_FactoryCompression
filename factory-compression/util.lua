local config = require("factory-compression.config")
local recipe_categories = require("factory-compression.compat.recipe_categories")

local util = {}

local locale_section_by_prototype_type = {
  recipe = "recipe-name",
  fluid = "fluid-name",
  ["assembling-machine"] = "entity-name",
  furnace = "entity-name",
  ["solar-panel"] = "entity-name",
  accumulator = "entity-name",
  boiler = "entity-name",
  generator = "entity-name",
  reactor = "entity-name",
  item = "item-name",
  ["item-with-entity-data"] = "item-name",
  module = "item-name",
  tool = "item-name",
  ammo = "item-name",
  armor = "item-name",
  capsule = "item-name",
  gun = "item-name",
  ["repair-tool"] = "item-name",
  ["rail-planner"] = "item-name",
  ["selection-tool"] = "item-name",
  ["copy-paste-tool"] = "item-name",
  blueprint = "item-name",
  ["blueprint-book"] = "item-name",
  ["deconstruction-item"] = "item-name",
  ["upgrade-item"] = "item-name",
  ["spidertron-remote"] = "item-name",
  ["space-platform-starter-pack"] = "item-name"
}

local recycling_recipe_categories = {
  recycling = true,
  ["recycling-or-hand-crafting"] = true
}

local localised_string_parameter_limit = 20

function util.starts_with(value, prefix)
  return type(value) == "string" and string.sub(value, 1, #prefix) == prefix
end

function util.copy_array(values)
  local copy = {}
  if type(values) ~= "table" then
    return copy
  end

  for _, value in ipairs(values) do
    table.insert(copy, value)
  end
  return copy
end

function util.sorted_keys(map)
  local keys = {}
  for key in pairs(map) do
    table.insert(keys, key)
  end
  table.sort(keys)
  return keys
end

function util.generated_entity_name(source_name)
  return config.ups_prefix .. source_name
end

function util.batch_recipe_name(source_name)
  return config.batch_recipe_prefix .. source_name
end

function util.category_name(source_name)
  return config.category_prefix .. source_name
end

local function format_number(value)
  local rounded = math.floor(value + 0.5)
  if math.abs(value - rounded) < 0.0000001 then
    return tostring(rounded)
  end

  local formatted = string.format("%.6f", value)
  formatted = string.gsub(formatted, "0+$", "")
  formatted = string.gsub(formatted, "%.$", "")
  return formatted
end

function util.multiply_energy(value, multiplier)
  if type(value) ~= "string" then
    return nil, "not-a-string"
  end

  local number, unit = string.match(value, "^%s*([%d%.]+)%s*([%a]+)%s*$")
  if not number or not unit then
    return nil, "unsupported-energy-format"
  end

  local numeric = tonumber(number)
  if not numeric then
    return nil, "unsupported-energy-number"
  end

  return format_number(numeric * multiplier) .. unit
end

function util.find_item(snapshot, name)
  if not name then
    return nil
  end

  return snapshot.items_by_name[name]
end

function util.item_exists(name)
  if not name then
    return false
  end

  for _, prototype_type in ipairs(config.item_prototype_types) do
    if data.raw[prototype_type] and data.raw[prototype_type][name] then
      return true
    end
  end

  return false
end

function util.product_name(product)
  if type(product) ~= "table" then
    return nil
  end

  if product.type ~= nil and product.type ~= "item" then
    return nil
  end

  return product.name or product[1]
end

function util.recipe_produces_item(recipe, item_name)
  if recipe.result == item_name then
    return true
  end

  if type(recipe.results) == "table" then
    for _, product in ipairs(recipe.results) do
      if util.product_name(product) == item_name then
        return true
      end
    end
  end

  return false
end

local function first_result_name(results)
  if type(results) ~= "table" or #results ~= 1 then
    return nil
  end

  local result = results[1]
  return util.product_name(result)
end

function util.find_source_item(snapshot, machine)
  if machine.minable then
    if machine.minable.result and util.find_item(snapshot, machine.minable.result) then
      return util.find_item(snapshot, machine.minable.result)
    end

    local result_name = first_result_name(machine.minable.results)
    if result_name and util.find_item(snapshot, result_name) then
      return util.find_item(snapshot, result_name)
    end
  end

  for _, item in ipairs(snapshot.items) do
    if item.prototype.place_result == machine.name then
      return item
    end
  end

  return nil
end

function util.add_unique(set, value)
  if value then
    set[value] = true
  end
end

function util.set_to_sorted_array(set)
  local values = {}
  for value in pairs(set) do
    table.insert(values, value)
  end
  table.sort(values)
  return values
end

local function append_localised_name_candidate(localised_string, candidate)
  if type(candidate) ~= "table" or not candidate.name then
    return
  end

  local prototype_localised_name = type(candidate.prototype) == "table" and candidate.prototype.localised_name or nil
  local is_internal_name = prototype_localised_name == candidate.name
    or (
      type(prototype_localised_name) == "table"
      and prototype_localised_name[1] == ""
      and prototype_localised_name[2] == candidate.name
      and prototype_localised_name[3] == nil
    )

  if prototype_localised_name ~= nil and not is_internal_name then
    table.insert(localised_string, table.deepcopy(candidate.prototype.localised_name))
  end

  local section = candidate.locale_section or locale_section_by_prototype_type[candidate.prototype_type]
  if section then
    table.insert(localised_string, {section .. "." .. candidate.name})
  end
end

function util.localised_name_from(candidates, fallback)
  local localised_string = {"?"}
  local last_name = nil

  if type(candidates) == "table" then
    for _, candidate in ipairs(candidates) do
      append_localised_name_candidate(localised_string, candidate)
      if type(candidate) == "table" and candidate.name then
        last_name = candidate.name
      end
    end
  end

  while #localised_string >= localised_string_parameter_limit do
    table.remove(localised_string)
  end

  table.insert(localised_string, tostring(fallback or last_name or ""))
  return localised_string
end

function util.localised_prototype_name(prototype_type, name, prototype, fallback)
  return util.localised_name_from({
    {
      prototype_type = prototype_type,
      name = name,
      prototype = prototype
    }
  }, fallback or name)
end

local function append_item_localised_name_candidates(candidates, snapshot, item_name)
  local item = util.find_item(snapshot, item_name)

  if item then
    table.insert(candidates, {
      prototype_type = item.prototype_type,
      name = item_name,
      prototype = item.prototype
    })

    if item.prototype.place_result then
      table.insert(candidates, {
        locale_section = "entity-name",
        name = item.prototype.place_result
      })
    end

    if item.prototype.place_as_equipment_result then
      table.insert(candidates, {
        locale_section = "equipment-name",
        name = item.prototype.place_as_equipment_result
      })
    end
  else
    table.insert(candidates, {
      prototype_type = "item",
      name = item_name
    })
  end
end

local function append_fluid_localised_name_candidate(candidates, snapshot, fluid_name)
  local fluid = snapshot.fluids_by_name and snapshot.fluids_by_name[fluid_name]
  table.insert(candidates, {
    prototype_type = "fluid",
    name = fluid_name,
    prototype = fluid and fluid.prototype
  })
end

local function append_product_localised_name_candidates(candidates, snapshot, product_name, product_type)
  if not product_name then
    return
  end

  if product_type == "fluid" then
    append_fluid_localised_name_candidate(candidates, snapshot, product_name)
  else
    append_item_localised_name_candidates(candidates, snapshot, product_name)
  end
end

local function recipe_product_display_name(product)
  if type(product) ~= "table" then
    return nil, nil
  end

  return product.name or product[1], product.type or "item"
end

local function append_matching_product_candidates(candidates, snapshot, recipe, product_name)
  local matched = false

  if recipe.result == product_name then
    append_product_localised_name_candidates(candidates, snapshot, product_name, "item")
    matched = true
  end

  if type(recipe.results) == "table" then
    for _, product in ipairs(recipe.results) do
      local result_name, result_type = recipe_product_display_name(product)
      if result_name == product_name then
        append_product_localised_name_candidates(candidates, snapshot, result_name, result_type)
        matched = true
      end
    end
  end

  if not matched then
    append_item_localised_name_candidates(candidates, snapshot, product_name)
    append_fluid_localised_name_candidate(candidates, snapshot, product_name)
  end
end

local function recipe_item_product_names(recipe)
  local names = {}

  if recipe.result then
    table.insert(names, recipe.result)
  end

  if type(recipe.results) == "table" then
    for _, product in ipairs(recipe.results) do
      local name = util.product_name(product)
      if name then
        table.insert(names, name)
      end
    end
  end

  return names
end

local function recipe_primary_item_name(recipe)
  if recipe.result then
    return recipe.result
  end

  local item_product_names = recipe_item_product_names(recipe)

  if recipe.main_product ~= nil and recipe.main_product ~= "" then
    for _, name in ipairs(item_product_names) do
      if name == recipe.main_product then
        return name
      end
    end
    return nil, "main-product-is-not-item-result"
  end

  if recipe.main_product == "" then
    return nil, "empty-main-product"
  end

  if #item_product_names == 1 then
    return item_product_names[1]
  end

  if #item_product_names == 0 then
    return nil, "no-item-products"
  end

  return nil, "multiple-item-products-without-main-product"
end

local function recipe_uses_recycling_category(recipe)
  for _, category in ipairs(recipe_categories.get(recipe)) do
    if recycling_recipe_categories[category] then
      return true, category
    end
  end

  return false
end

function util.recipe_is_regular_source_for_item(recipe, item_name)
  if type(recipe) ~= "table" then
    return false, "invalid-recipe"
  end

  if recipe.hidden == true then
    return false, "hidden-source-recipe"
  end

  if recipe.parameter == true then
    return false, "parameter-source-recipe"
  end

  if recipe.normal or recipe.expensive then
    return false, "difficulty-variant-recipe"
  end

  local uses_recycling_category, category = recipe_uses_recycling_category(recipe)
  if uses_recycling_category then
    return false, "recycling-source-recipe", category
  end

  local primary_name, reason = recipe_primary_item_name(recipe)
  if primary_name ~= item_name then
    return false, reason or "item-is-not-primary-product"
  end

  return true
end

function util.regular_source_recipe_names_for_item(snapshot, item_name)
  local names = {}
  local excluded = {}

  for _, recipe in ipairs(snapshot.recipes or {}) do
    if util.recipe_produces_item(recipe.prototype, item_name) then
      local ok, reason, detail = util.recipe_is_regular_source_for_item(recipe.prototype, item_name)
      if ok then
        table.insert(names, recipe.name)
      else
        reason = reason or "not-regular-source-recipe"
        excluded[reason] = (excluded[reason] or 0) + 1
        if detail then
          excluded[reason .. ":" .. tostring(detail)] = (excluded[reason .. ":" .. tostring(detail)] or 0) + 1
        end
      end
    end
  end

  table.sort(names)
  return names, excluded
end

function util.localised_recipe_name(snapshot, recipe_name, recipe)
  local candidates = {
    {
      prototype_type = "recipe",
      name = recipe_name,
      prototype = recipe
    }
  }

  if type(recipe) ~= "table" then
    return util.localised_name_from(candidates, recipe_name)
  end

  if recipe.main_product and recipe.main_product ~= "" then
    append_matching_product_candidates(candidates, snapshot, recipe, recipe.main_product)
  elseif recipe.result then
    append_product_localised_name_candidates(candidates, snapshot, recipe.result, "item")
  elseif type(recipe.results) == "table" then
    for _, product in ipairs(recipe.results) do
      local product_name, product_type = recipe_product_display_name(product)
      append_product_localised_name_candidates(candidates, snapshot, product_name, product_type)
    end
  end

  return util.localised_name_from(candidates, recipe_name)
end

return util
