-- Copyright 2021 SmartThings
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

--- @type st.capabilities
local capabilities = require "st.capabilities"
local ZwaveDriver = require "st.zwave.driver"
local defaults = require "st.zwave.defaults"
local update_preferences = require "update_preferences"

---
--- @param self st.zwave.Driver
--- @param device st.zwave.Device
local function updateFirmwareVersion(self, device)
  -- Set our zwave deviceNetworkID 
  for _, component in pairs(device.profile.components) do
    if device:supports_capability_by_id(capabilities.firmwareUpdate.ID, component.id) then
      local fw_major = (((device.st_store or {}).zwave_version or {}).firmware or {}).major
      local fw_minor = (((device.st_store or {}).zwave_version or {}).firmware or {}).minor
      if fw_major and fw_minor then
        local fmtFirmwareVersion= fw_major .. "." .. string.format('%02d',fw_minor)
        device:emit_component_event(component,capabilities.firmwareUpdate.currentVersion({value = fmtFirmwareVersion }))
      end
    end
  end
end

--- Initialize device
---
--- @param self st.zwave.Driver
--- @param device st.zwave.Device
local device_init = function(self, device)
end

--- @param driver st.zwave.Driver
--- @param device st.zwave.Device
local function info_changed(driver, device, event, args)
  update_preferences(driver, device, args)
end

--- @param driver st.zwave.Driver
--- @param device st.zwave.Device
local function device_added(driver, device)
  updateFirmwareVersion(driver, device)
  device:refresh()
end

local driver_template = {
  lifecycle_handlers = {
    init           = device_init,
    infoChanged    = info_changed,
    added          = device_added,
  },
  supported_capabilities = {
    capabilities.alarm,
    capabilities.battery,
    capabilities.switch,
    capabilities.tamperAlert,
    capabilities.temperatureMeasurement,
    capabilities.relativeHumidityMeasurement,
    capabilities.switchLevel,   -- maps a "dimmer" to the 0-99 chimes
    capabilities.refresh,
    capabilities.tone,   -- older capability, uses beep()
    capabilities.audioVolume,
  },
  sub_drivers = {
    require("zooz-zse19"),
  },
  NAME = "zwave-siren",
}

defaults.register_for_default_handlers(driver_template, driver_template.supported_capabilities)
local zwave_siren = ZwaveDriver("zwave-siren", driver_template)
zwave_siren:run()