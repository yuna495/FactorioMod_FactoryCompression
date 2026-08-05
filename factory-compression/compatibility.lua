local compatibility = {}

compatibility.machine_whitelist = {
  ["assembling-machine"] = {},
  furnace = {}
}

compatibility.machine_blacklist = {
  ["assembling-machine"] = {},
  furnace = {}
}

compatibility.power_entity_whitelist = {
  ["solar-panel"] = {},
  accumulator = {}
}

compatibility.power_entity_blacklist = {
  ["solar-panel"] = {},
  accumulator = {}
}

compatibility.recipe_whitelist = {}
compatibility.recipe_blacklist = {}

compatibility.machine_ingredient_overrides = {}

function compatibility.is_machine_whitelisted(prototype_type, name)
  local by_type = compatibility.machine_whitelist[prototype_type]
  return by_type and by_type[name] == true
end

function compatibility.get_machine_blacklist_reason(prototype_type, name)
  local by_type = compatibility.machine_blacklist[prototype_type]
  if not by_type then
    return nil
  end

  local value = by_type[name]
  if value == true then
    return "blacklisted"
  end
  return value
end

function compatibility.is_power_entity_whitelisted(prototype_type, name)
  local by_type = compatibility.power_entity_whitelist[prototype_type]
  return by_type and by_type[name] == true
end

function compatibility.get_power_entity_blacklist_reason(prototype_type, name)
  local by_type = compatibility.power_entity_blacklist[prototype_type]
  if not by_type then
    return nil
  end

  local value = by_type[name]
  if value == true then
    return "blacklisted"
  end
  return value
end

function compatibility.is_recipe_whitelisted(name)
  return compatibility.recipe_whitelist[name] == true
end

function compatibility.get_recipe_blacklist_reason(name)
  local value = compatibility.recipe_blacklist[name]
  if value == true then
    return "blacklisted"
  end
  return value
end

return compatibility
