local config = require("factory-compression.config")

local logger = {}

local function new_counter()
  return {
    total = 0,
    by_reason = {}
  }
end

function logger.new(detailed)
  local instance = {
    detailed = detailed == true,
    generated = {
      categories = {},
      machines = {},
      solar_panels = {},
      accumulators = {},
      items = {},
      equipment_recipes = {},
      batch_recipes = {},
      technologies = {}
    },
    appearance = {
      tinted = {},
      skipped = {}
    },
    excluded = {
      machines = new_counter(),
      recipes = new_counter(),
      categories = new_counter(),
      power_entities = new_counter(),
      errors = new_counter()
    },
    notes = {}
  }

  return setmetatable(instance, {__index = logger})
end

function logger:generated_prototype(kind, name)
  if self.generated[kind] then
    table.insert(self.generated[kind], name)
  end

  if self.detailed then
    log(config.log_prefix .. " generated " .. kind .. ": " .. name)
  end
end

function logger:exclude(kind, name, reason, detail, always_log)
  local bucket = self.excluded[kind]
  if not bucket then
    bucket = self.excluded.errors
  end

  bucket.total = bucket.total + 1
  bucket.by_reason[reason] = (bucket.by_reason[reason] or 0) + 1

  if always_log or self.detailed or kind == "errors" then
    local message = config.log_prefix .. " excluded " .. kind .. " '" .. tostring(name) .. "': " .. tostring(reason)
    if detail then
      message = message .. " (" .. tostring(detail) .. ")"
    end
    log(message)
  end
end

function logger:note(key, value)
  self.notes[key] = (self.notes[key] or 0) + (value or 1)
end

function logger:appearance_result(name, tinted_layers, reason)
  if tinted_layers > 0 then
    table.insert(self.appearance.tinted, name)
    if self.detailed then
      log(config.log_prefix .. " tinted machine '" .. name .. "': layers=" .. tinted_layers)
    end
  else
    table.insert(self.appearance.skipped, name)
    if self.detailed then
      log(config.log_prefix .. " kept original machine graphics '" .. name .. "': " .. tostring(reason or "no-safe-layer"))
    end
  end
end

local function count(list)
  return #list
end

local function sorted_keys(map)
  local keys = {}
  for key in pairs(map) do
    table.insert(keys, key)
  end
  table.sort(keys)
  return keys
end

function logger:summary()
  log(config.log_prefix .. " summary: categories=" .. count(self.generated.categories)
    .. ", machines=" .. count(self.generated.machines)
    .. ", solar_panels=" .. count(self.generated.solar_panels)
    .. ", accumulators=" .. count(self.generated.accumulators)
    .. ", items=" .. count(self.generated.items)
    .. ", equipment_recipes=" .. count(self.generated.equipment_recipes)
    .. ", batch_recipes=" .. count(self.generated.batch_recipes)
    .. ", technologies=" .. count(self.generated.technologies))

  log(config.log_prefix .. " appearance: tinted_machines=" .. count(self.appearance.tinted)
    .. ", original_graphics_machines=" .. count(self.appearance.skipped))

  for kind, bucket in pairs(self.excluded) do
    if bucket.total > 0 then
      local parts = {}
      for _, reason in ipairs(sorted_keys(bucket.by_reason)) do
        table.insert(parts, reason .. "=" .. bucket.by_reason[reason])
      end
      log(config.log_prefix .. " excluded " .. kind .. ": total=" .. bucket.total .. " [" .. table.concat(parts, ", ") .. "]")
    end
  end

  if self.notes.final_tier_candidates then
    log(config.log_prefix .. " final tier candidates without next_upgrade: " .. self.notes.final_tier_candidates)
  end
end

return logger
