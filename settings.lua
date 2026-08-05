data:extend({
  {
    type = "string-setting",
    name = "factory-compression-multiplier",
    setting_type = "startup",
    default_value = "10",
    allowed_values = {"5", "10", "20", "50"},
    order = "a"
  },
  {
    type = "bool-setting",
    name = "factory-compression-detailed-logging",
    setting_type = "startup",
    default_value = false,
    order = "b"
  },
  {
    type = "int-setting",
    name = "factory-compression-speed-module-3-count",
    setting_type = "startup",
    default_value = 5,
    minimum_value = 0,
    maximum_value = 1000,
    order = "c-a"
  },
  {
    type = "int-setting",
    name = "factory-compression-productivity-module-3-count",
    setting_type = "startup",
    default_value = 5,
    minimum_value = 0,
    maximum_value = 1000,
    order = "c-b"
  },
  {
    type = "int-setting",
    name = "factory-compression-efficiency-module-3-count",
    setting_type = "startup",
    default_value = 5,
    minimum_value = 0,
    maximum_value = 1000,
    order = "c-c"
  }
})
