-- Copyright 2022 SmartThings
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

local clusters = require "st.zigbee.zcl.clusters"
local PowerConfiguration = clusters.PowerConfiguration

local devices = {
  LINKIND_WATER_LEAK_SENSOR = {
    FINGERPRINTS = {
      { mfr = "LK", model = "A001082" }
    },
    CONFIGURATION = {
      {
        cluster   = PowerConfiguration.ID,
        attribute = PowerConfiguration.attributes.BatteryVoltage.ID,  -- 0x0020
        data_type = PowerConfiguration.attributes.BatteryVoltage.base_type,
        minimum_interval = 60,            -- in seconds
        maximum_interval = 12 * 60 * 60,  -- in seconds
        reportable_change = 1             -- 1 = .1V
      },
      {
        cluster   = PowerConfiguration.ID,
        attribute = PowerConfiguration.attributes.BatteryPercentageRemaining.ID,  -- 0x021
        data_type = PowerConfiguration.attributes.BatteryPercentageRemaining.base_type,
        minimum_interval  = 60,
        maximum_interval  = 12 * 60 * 60,
        reportable_change = 2            -- in units of .5% (2 = 1%)
      }
    }
  },
}

local configurations = {}

configurations.get_device_configuration = function(zigbee_device)
  for _, device in pairs(devices) do
    for _, fingerprint in pairs(device.FINGERPRINTS) do
      if zigbee_device:get_manufacturer() == fingerprint.mfr and zigbee_device:get_model() == fingerprint.model then
        return device.CONFIGURATION
      end
    end
  end
  return nil
end

return configurations
