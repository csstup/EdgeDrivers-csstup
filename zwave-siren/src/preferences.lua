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

local devices = {
 -- mfr:"027A", prod:"000C", model:"0003", deviceJoinName: "Zooz S2 Multisiren"
  ZOOZ_ZSE19 = {
    MATCHING_MATRIX = {
      mfrs = 0x027A,
      product_types = 0x000C,
      product_ids = 0x0003,
    },
    PARAMETERS = {
      alarmDuration           = {type = 'config', parameter_number = 1, size = 1},
      tempHumidityInterval    = {type = 'config', parameter_number = 2, size = 2},
      toneSound               = {type = 'config', parameter_number = 3, size = 1}, 

      soundVolume             = {type = 'soundvol'},

      assocGroup1             = {type = 'assoc', group = 1, maxnodes = 5, addhub = false},
    }
  },
}
local preferences = {}

preferences.get_device_parameters = function(zw_device)
  for _, device in pairs(devices) do
    if zw_device:id_match(
      device.MATCHING_MATRIX.mfrs,
      device.MATCHING_MATRIX.product_types,
      device.MATCHING_MATRIX.product_ids) then
      return device.PARAMETERS
    end
  end
  return nil
end

preferences.to_numeric_value = function(new_value)
  local numeric = tonumber(new_value)
  if numeric == nil then -- in case the value is boolean
    numeric = new_value and 1 or 0
  end
  return numeric
end

return preferences
