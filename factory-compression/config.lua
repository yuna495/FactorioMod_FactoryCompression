local config = {}

config.mod_name = "FactoryCompression"
config.log_prefix = "[FactoryCompression]"

config.generated_prefix = "factory-compression-"
config.ups_prefix = "factory-compression-ups-"
config.batch_recipe_prefix = "factory-compression-batch-"
config.category_prefix = "factory-compression-"
config.technology_name = "factory-compression-ups-machines"
config.power_technology_name = "factory-compression-ups-power"
config.overlay_icon = "__FactoryCompression__/graphics/icons/ups-overlay.png"

config.ups_tint = {r = 0.85, g = 0.12, b = 0.12, a = 1.0}

config.supported_machine_types = {
  "assembling-machine",
  "furnace"
}

config.supported_power_types = {
  "solar-panel",
  "accumulator"
}

config.item_prototype_types = {
  "item",
  "item-with-entity-data",
  "module",
  "tool",
  "ammo",
  "armor",
  "capsule",
  "gun",
  "repair-tool",
  "rail-planner",
  "selection-tool",
  "copy-paste-tool",
  "blueprint",
  "blueprint-book",
  "deconstruction-item",
  "upgrade-item",
  "spidertron-remote",
  "space-platform-starter-pack"
}

config.item_amount_max = 65535

config.non_stackable_item_types = {
  blueprint = true,
  ["blueprint-book"] = true,
  ["copy-paste-tool"] = true,
  ["deconstruction-item"] = true,
  ["selection-tool"] = true,
  ["spidertron-remote"] = true,
  ["upgrade-item"] = true
}

return config
