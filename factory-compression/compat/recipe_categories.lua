local recipe_categories = {}

local cached_is_21 = nil

local function split_version(version)
  if type(version) ~= "string" or version == "" then
    error("FactoryCompression invalid Factorio version: " .. tostring(version))
  end

  local parts = {}
  for part in string.gmatch(version, "[^%.]+") do
    if not string.match(part, "^%d+$") then
      error("FactoryCompression invalid Factorio version segment: " .. tostring(version))
    end
    table.insert(parts, tonumber(part))
  end

  if #parts == 0 then
    error("FactoryCompression invalid Factorio version: " .. tostring(version))
  end

  return parts
end

local function fallback_compare_versions(first, second)
  local first_parts = split_version(first)
  local second_parts = split_version(second)
  local length = math.max(#first_parts, #second_parts)

  for index = 1, length do
    local first_part = first_parts[index] or 0
    local second_part = second_parts[index] or 0
    if first_part < second_part then
      return -1
    elseif first_part > second_part then
      return 1
    end
  end

  return 0
end

local function compare_versions(first, second)
  if helpers and helpers.compare_versions then
    return helpers.compare_versions(first, second)
  end

  return fallback_compare_versions(first, second)
end

function recipe_categories.is_21_or_newer()
  if cached_is_21 ~= nil then
    return cached_is_21
  end

  local base_version = mods and mods.base or "2.0.0"
  cached_is_21 = compare_versions(base_version, "2.1.0") >= 0
  return cached_is_21
end

local function append_unique(target, seen, value)
  if value and not seen[value] then
    seen[value] = true
    table.insert(target, value)
  end
end

local function normalize(categories)
  local normalized = {}
  local seen = {}

  if type(categories) == "table" then
    for _, category in ipairs(categories) do
      append_unique(normalized, seen, category)
    end
  end

  if #normalized == 0 then
    table.insert(normalized, "crafting")
  end

  return normalized
end

function recipe_categories.get(recipe)
  if recipe_categories.is_21_or_newer() and type(recipe.categories) == "table" then
    return normalize(recipe.categories)
  end

  local categories = {}
  local seen = {}
  append_unique(categories, seen, recipe.category or "crafting")

  if type(recipe.additional_categories) == "table" then
    for _, category in ipairs(recipe.additional_categories) do
      append_unique(categories, seen, category)
    end
  end

  return normalize(categories)
end

function recipe_categories.set(recipe, categories)
  local normalized = normalize(categories)

  if recipe_categories.is_21_or_newer() then
    recipe.categories = normalized
    recipe.category = nil
    recipe.additional_categories = nil
    return
  end

  recipe.category = normalized[1]
  recipe.categories = nil

  if #normalized > 1 then
    recipe.additional_categories = {}
    for index = 2, #normalized do
      table.insert(recipe.additional_categories, normalized[index])
    end
  else
    recipe.additional_categories = nil
  end
end

return recipe_categories
