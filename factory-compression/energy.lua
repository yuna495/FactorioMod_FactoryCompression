local util = require("factory-compression.util")

local energy = {}

function energy.scale_energy_usage(value, multiplier)
  return util.multiply_energy(value, multiplier)
end

function energy.scale_emissions_per_minute(emissions_per_minute, multiplier)
  if emissions_per_minute == nil then
    return true
  end

  if type(emissions_per_minute) ~= "table" then
    return false, "unsupported-emissions-per-minute", "not-a-table"
  end

  for pollutant, amount in pairs(emissions_per_minute) do
    if type(amount) ~= "number" then
      return false, "unsupported-emissions-per-minute", tostring(pollutant)
    end
    emissions_per_minute[pollutant] = amount * multiplier
  end

  return true
end

function energy.scale_energy_source(energy_source, multiplier)
  if type(energy_source) ~= "table" then
    return true
  end

  if energy_source.drain ~= nil then
    local scaled, reason = util.multiply_energy(energy_source.drain, multiplier)
    if not scaled then
      return false, "unsupported-electric-drain", reason
    end
    energy_source.drain = scaled
  end

  local ok, reason, detail = energy.scale_emissions_per_minute(energy_source.emissions_per_minute, multiplier)
  if not ok then
    return false, reason, detail
  end

  return true
end

return energy
