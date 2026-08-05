local config = require("factory-compression.config")

local appearance = {}

local direction_fields = {"north", "east", "south", "west"}
local entity_animation_fields = {"animation", "idle_animation"}
local graphics_set_animation_fields = {"animation", "idle_animation"}

local function icon_layer_from(prototype)
  if type(prototype) ~= "table" then
    return nil
  end

  if type(prototype.icons) == "table" then
    return table.deepcopy(prototype.icons)
  end

  if prototype.icon then
    return {
      {
        icon = prototype.icon,
        icon_size = prototype.icon_size,
        icon_mipmaps = prototype.icon_mipmaps
      }
    }
  end

  return nil
end

function appearance.apply_icon_overlay(target, source)
  local icons = icon_layer_from(source or target)
  if not icons then
    return false
  end

  table.insert(icons, {
    icon = config.overlay_icon,
    icon_size = 64
  })

  target.icons = icons
  target.icon = nil
  target.icon_size = nil
  target.icon_mipmaps = nil
  return true
end

local function can_tint_layer(layer)
  if type(layer) ~= "table" then
    return false
  end

  if layer.draw_as_shadow or layer.draw_as_light or layer.draw_as_glow then
    return false
  end

  if layer.apply_runtime_tint or layer.tint then
    return false
  end

  if layer.blend_mode and layer.blend_mode ~= "normal" then
    return false
  end

  return layer.filename ~= nil or layer.filenames ~= nil or layer.stripes ~= nil
end

local function tint_layer(layer)
  if can_tint_layer(layer) then
    layer.tint = table.deepcopy(config.ups_tint)
    return 1
  end

  return 0
end

local function tint_animation(animation)
  if type(animation) ~= "table" then
    return 0
  end

  local tinted = 0

  if type(animation.layers) == "table" then
    for _, layer in ipairs(animation.layers) do
      tinted = tinted + tint_animation(layer)
    end
  else
    tinted = tinted + tint_layer(animation)
  end

  if type(animation.hr_version) == "table" then
    tinted = tinted + tint_animation(animation.hr_version)
  end

  for _, field in ipairs(direction_fields) do
    if type(animation[field]) == "table" then
      tinted = tinted + tint_animation(animation[field])
    end
  end

  return tinted
end

function appearance.apply_entity_tint(entity)
  local tinted = 0

  for _, field in ipairs(entity_animation_fields) do
    tinted = tinted + tint_animation(entity[field])
  end

  if type(entity.graphics_set) == "table" then
    for _, field in ipairs(graphics_set_animation_fields) do
      tinted = tinted + tint_animation(entity.graphics_set[field])
    end
  end

  return tinted
end

return appearance
