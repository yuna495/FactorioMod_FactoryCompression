local config = require("factory-compression.config")

local util = {}

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

local function first_result_name(results)
  if type(results) ~= "table" or #results ~= 1 then
    return nil
  end

  local result = results[1]
  if type(result) == "table" and (result.type == nil or result.type == "item") then
    return result.name or result[1]
  end

  return nil
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

return util
