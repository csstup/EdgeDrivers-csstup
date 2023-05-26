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

-- inClusters: 0000,0001,0003,0004,0005,0006,0B04,0B05
-- outClusters: 0000,0001,0003,0004,0005,0006,0019,0B04,0B05

local device_management = require "st.zigbee.device_management"

-- Capabilities
local capabilities = require "st.capabilities"

-- Zigbee Clusters
local clusters = require "st.zigbee.zcl.clusters"
local Basic = clusters.Basic
local PowerConfiguration = clusters.PowerConfiguration -- 0x0001
local ElectricalMeasurement = clusters.ElectricalMeasurement
local Identify = clusters.Identify

local utils = require "st.utils"
local constants = require "st.zigbee.constants"

constants.VOLTAGE_MEASUREMENT_MULTIPLIER_KEY = "_voltage_measurement_multiplier"
constants.VOLTAGE_MEASUREMENT_DIVISOR_KEY = "_voltage_measurement_divisor"
constants.CURRENT_MEASUREMENT_MULTIPLIER_KEY = "_current_measurement_multiplier"
constants.CURRENT_MEASUREMENT_DIVISOR_KEY = "_current_measurement_divisor"

-- Utility 
local log = require "log"

-- Globals 
NeedsRefresh = false

local function can_handle_peanut_plug(opts, driver, device)
  -- This driver always handles the peanut plug
  return true
end

local function round(num, numDecimalPlaces)
  local mult = 10^(numDecimalPlaces or 0)
  return math.floor(num * mult + 0.5) / mult
end

local function call_parent_handler(handlers, self, device, event, args)
  if type(handlers) == "function" then
    handlers = { handlers }  -- wrap as table
  end
  for _, func in ipairs( handlers or {} ) do
      func(self, device, event, args)
  end
end

local divisors = {
  power_multiplier   = { key = constants.ELECTRICAL_MEASUREMENT_MULTIPLIER_KEY, default = 0x280F },
  power_divisor      = { key = constants.ELECTRICAL_MEASUREMENT_DIVISOR_KEY,    default = 0x9999 },
  voltage_multiplier = { key = constants.VOLTAGE_MEASUREMENT_MULTIPLIER_KEY,    default = 0xB4   },
  voltage_divisor    = { key = constants.VOLTAGE_MEASUREMENT_DIVISOR_KEY,       default = 0x9999 },
  current_multiplier = { key = constants.CURRENT_MEASUREMENT_MULTIPLIER_KEY,    default = 0x48   },
  current_divisor    = { key = constants.CURRENT_MEASUREMENT_DIVISOR_KEY,       default = 0x9999 },
}

-- Get the current divisor data or default if not set yet.
local function get_divisor_data(device)
  local d = {}
  for key, value in pairs(divisors) do
    d[key] = device:get_field(value.key) or value.default
  end
  return d
end

local function clear_divisor_keys(device)
  for _, value in pairs(divisors) do
    device:set_field(value.key, nil)
  end
end

--
local function are_divisors_synced(device)
  if device:get_field(constants.ELECTRICAL_MEASUREMENT_MULTIPLIER_KEY) ~= nil and
     device:get_field(constants.ELECTRICAL_MEASUREMENT_DIVISOR_KEY) ~= nil and
     device:get_field(constants.VOLTAGE_MEASUREMENT_MULTIPLIER_KEY) ~= nil and
     device:get_field(constants.VOLTAGE_MEASUREMENT_DIVISOR_KEY) ~= nil and
     device:get_field(constants.CURRENT_MEASUREMENT_MULTIPLIER_KEY) ~= nil and
     device:get_field(constants.CURRENT_MEASUREMENT_DIVISOR_KEY) ~= nil then
    return true
  end
  return false
end

local cluster_base = require "st.zigbee.cluster_base"
local data_types = require "st.zigbee.data_types"
local zcl_messages = require "st.zigbee.zcl"
local messages = require "st.zigbee.messages"
local read_attribute = require "st.zigbee.zcl.global_commands.read_attribute"
local zb_const = require "st.zigbee.constants"

--- Helper method for reading a list of cluster attributes
---
--- @param device st.Device the device to send the command to
--- @param cluster_id st.zigbee.data_types.ClusterId the cluster id of the cluster the attribute is a part of
--- @param attr_ids st.zigbee.data_types.AttributeId[] A list of the AttributeIds to be read
--- @return st.zigbee.ZigbeeMessageTx the ReadAttribute command
local function read_attribute_list(device, cluster_id, attr_ids)
  local read_body = read_attribute.ReadAttribute(attr_ids)
  local zclh = zcl_messages.ZclHeader({
    cmd = data_types.ZCLCommandId(read_attribute.ReadAttribute.ID)
  })
  local addrh = messages.AddressHeader(
      zb_const.HUB.ADDR,
      zb_const.HUB.ENDPOINT,
      device:get_short_address(),
      device:get_endpoint(cluster_id.value),
      zb_const.HA_PROFILE_ID,
      cluster_id.value
  )
  local message_body = zcl_messages.ZclMessageBody({
    zcl_header = zclh,
    zcl_body = read_body
  })
  return messages.ZigbeeMessageTx({
    address_header = addrh,
    body = message_body
  })
end

-- Lifecycle notes:
-- On new device added:
--  event: added  (sometimes init is before added...)
--  event: init   (sometimes added is before init...)
--  event: doConfigure
--  event: infoChanged
-- On reboot of hub/reinit of existing device:
--  event: init
-- On driver update (new version published)
--  event: init
-- On driver update (same version published)
--  event: infoChanged

-- On driver change (from another driver to this one)
--   event: init
--   event: added
--   event: driverSwitched (instead of doConfigure)
--   event: infoChanged    (but with an unchanged preferences)
--   capability: Refresh called, runs command refresh

-- On device re-pairing (existing device)
--   event: infoChanged (parallel with doConfigure)
--   event: doConfigure 

-- actual_value = scaled_value * multiplier / Divisor
-- to get the scaled value from the actual value, do the inverse
-- scaled_value = actual_value * divisor / multipler

local function update_attribute_reporting(device, capability, intervalSeconds, attr_config)
  if device:supports_capability(capability) then
    device:add_configured_attribute(attr_config)
    if intervalSeconds > 0 then
      device:add_monitored_attribute(attr_config)
    else
      device:remove_monitored_attribute(attr_config.cluster, attr_config.attribute)
    end
  end
end

-- This sets up the configuration data interanally, but does not actually configure the device.
--- @param self st.zigbee.Driver
--- @param device st.zigbee.Device
--- @param intervalMinutes number
--- @param intervalMax number
local function configure_reporting(self, device, intervalMinutes, intervalMax)
  -- Configure power, voltage and current attributes for reporting.
  device.log.trace("configure_reporting() interval = " .. intervalMinutes .. " max = " .. intervalMax)

  local intervalSeconds = intervalMinutes * 60
  local intervalMaxSeconds = intervalMax * 60

  local divisors = get_divisor_data(device)

  local power_change   = device.preferences['powerReporting'] * divisors.power_divisor / divisors.power_multiplier 
  local voltage_change = device.preferences['voltageReporting'] * divisors.voltage_divisor / divisors.voltage_multiplier
  local current_change = device.preferences['currentReporting'] * divisors.current_divisor / divisors.current_multiplier

  if intervalMinutes == 0 or intervalMax == 0 then
    -- If our divisors aren't available or we have prefences set to disable monitoring
    device.log.debug("Reporting disabled")
    -- Set the reporting configurations to DISABLED
    -- Min == 0, Max == 0xFFFF = Disable reporting
    intervalSeconds = 0
    intervalMaxSeconds = 0xFFFF
  end

  local active_power_reporting = {
    cluster   = ElectricalMeasurement.ID,
    attribute = ElectricalMeasurement.attributes.ActivePower.ID, 
    data_type = ElectricalMeasurement.attributes.ActivePower.base_type,
    minimum_interval  = intervalSeconds,
    maximum_interval  = intervalMaxSeconds,
    reportable_change = math.floor(power_change),   -- in W, needs to be scaled
  }

  local voltage_reporting = {
    cluster   = ElectricalMeasurement.ID,
    attribute = ElectricalMeasurement.attributes.RMSVoltage.ID,
    data_type = ElectricalMeasurement.attributes.RMSVoltage.base_type,
    minimum_interval  = intervalSeconds,
    maximum_interval  = intervalMaxSeconds,
    reportable_change = math.floor(voltage_change),   -- In VAC, needs to be scaled
  }

  local active_current_reporting = {
    cluster   = ElectricalMeasurement.ID,
    attribute = ElectricalMeasurement.attributes.RMSCurrent.ID, 
    data_type = ElectricalMeasurement.attributes.RMSCurrent.base_type,
    minimum_interval  = intervalSeconds,
    maximum_interval  = intervalMaxSeconds,
    reportable_change = math.floor(current_change),   -- In A, needs to be scaled
  }

  update_attribute_reporting(device, capabilities.powerMeter, intervalSeconds, active_power_reporting)
  update_attribute_reporting(device, capabilities.voltageMeasurement, intervalSeconds, voltage_reporting)
  update_attribute_reporting(device, capabilities.currentMeasurement, intervalSeconds, active_current_reporting)
end

--- @param self ZigbeeDriver
--- @param device st.zigbee.Device 
local function retrieve_power_divisors(self, device)
   local default_power_attributes = {}
   local child_power_attributes = {}

    -- Get multipliers and divisors for all 3 power 
    if device:supports_capability(capabilities.powerMeter) then
      table.insert(default_power_attributes, data_types.AttributeId(ElectricalMeasurement.attributes.ACPowerDivisor.ID))
      table.insert(default_power_attributes, data_types.AttributeId(ElectricalMeasurement.attributes.ACPowerMultiplier.ID))
      -- device:send(ElectricalMeasurement.attributes.ACPowerDivisor:read(device))
      -- device:send(ElectricalMeasurement.attributes.ACPowerMultiplier:read(device))
    end
  
    if device:supports_capability(capabilities.voltageMeasurement) then
      table.insert(child_power_attributes, data_types.AttributeId(ElectricalMeasurement.attributes.ACVoltageDivisor.ID))
      table.insert(child_power_attributes, data_types.AttributeId(ElectricalMeasurement.attributes.ACVoltageMultiplier.ID))
      --device:send(ElectricalMeasurement.attributes.ACVoltageDivisor:read(device))
      --device:send(ElectricalMeasurement.attributes.ACVoltageMultiplier:read(device))
    end
  
    if device:supports_capability(capabilities.currentMeasurement) then
      table.insert(child_power_attributes, data_types.AttributeId(ElectricalMeasurement.attributes.ACCurrentDivisor.ID))
      table.insert(child_power_attributes, data_types.AttributeId(ElectricalMeasurement.attributes.ACCurrentMultiplier.ID))
      --device:send(ElectricalMeasurement.attributes.ACCurrentDivisor:read(device))
      --device:send(ElectricalMeasurement.attributes.ACCurrentMultiplier:read(device))
    end

    -- TODO: Reading mulitple attributes does not work as expected yet.
    --       The dispatching of handlers on receive is tied to a single level
    --       which is whatever attribute is read first on the multiple list.
    --       If we have all our handlers at the same driver level, this will work fine
    --       but since we're using the default handlers for 2 of the 6 atttibutes 
    --       we won't parse them correctly.
    -- So instead, send the 2 we know go default as one set, and the other 4 that we handle
    -- to a second set.
    device:send(read_attribute_list(device, data_types.ClusterId(ElectricalMeasurement.ID),  default_power_attributes ))
    device:send(read_attribute_list(device, data_types.ClusterId(ElectricalMeasurement.ID),  child_power_attributes ))
end


-- Update the device's preferences.
-- Then update the reporting configuration on the device, if its
--- @param self ZigbeeDriver 
--- @param device st.zigbee.Device
local function updatePreferences(self, device, args)
  local value = device.preferences['retainState']
  if (not (args and args.old_st_store) or (args.old_st_store.preferences['retainState'] ~= value)) then
    -- Update preferences on device
    if (value == nil) or value ~= false then
      -- not set or not false, retain state
      device:send(Identify.attributes.IdentifyTime:write(device, 0x0000))
    else
      -- Don't retain state
      device:send(Identify.attributes.IdentifyTime:write(device, 0x1111))
    end
  end

  -- If we don't have args then force the update to reporting configuration
  local updateReporting = not (args and args.old_st_store)

  -- Prefences in this list will trigger an update to configure reporting.
  local reporting_prefs = {
    'powerInterval',
    'powerIntervalMax',
    'powerReporting',
    'voltageReporting',
    'currentReporting'
  }

  for _, prefId in pairs(reporting_prefs) do
    value = device.preferences[prefId]
    if (not (args and args.old_st_store) or (args.old_st_store.preferences[prefId] ~= value)) then
      updateReporting = true
    end
  end

  if updateReporting then
    -- Queue the reporting configuration.   It may not run immediately
    device.log.trace("Scheduling reporting configuration...")
    device.thread:queue_event(self.lifecycle_dispatcher.dispatch, self.lifecycle_dispatcher, self, device, "configureReporting", { attempts_remaining = 10 })
  end
end

-- For testing keys being persisted into init.
-- Specifically between driverSwitched events.
local function init_key_test(device)
  local value = device:get_field("test_key")
  value = value and value or "nil"
  print ("field value of test_key on pre init: " .. value)
  
  -- DEBUG PERSISTENT KEYS
  -- If this is a driverSwitched event, test_key should not yet have a value.

  device:set_field("test_key", 47, {persist = true})

  value = device:get_field("test_key")
  value = value and value or "nil"
  print ("field value of test_key on post init: " .. value)
end


-- lifecycle init handler
-- Called when a device object needs to be instantiated within the driver.
--- 1) the driver just started up and needs to create the objects for existing devices and
--- 2) a device was newly added to the driver.
-- We do any actions here both for newly added devices AND after reboot. 
-- We don't send any data to the device as the zigbee radio may not be ready (in the case of reboot)
--  or sleepy devices may not be listening anyway.
--- @param self ZigbeeDriver The current driver running containing necessary context for execution
--- @param device st.zigbee.Device The device this message was received from containing identifying information
local function do_init(self, device, event, args)

  -- DEBUG PERSISTENT KEYS:
  -- It seems like keys set with persist are not being cleared between driverSwitched events.
  -- Test that behaviour:
  init_key_test(device)

  -- Do the parent init stuff first
  call_parent_handler(self.lifecycle_handlers.init, self, device, event, args)

  -- And now the local init for this driver.

  -- Setup the driver's internal attribute configuration tables.  
  -- This will allow us to do configure() and refresh() for any configured attributes.
  -- We will update these again as needed.   This initial copy is mainly for 
  -- when the driver is initialized again.
  configure_reporting(self, device, device.preferences['powerInterval'], device.preferences['powerIntervalMax'])

  --- For debugging what our configuration persistent data looks like
  -- print (utils.stringify_table(device:get_field("__configured_attributes"), "device cluster_configurations:", true))
end

-- lifecycle 'doConfigure' handler
-- called on both added and driver changed.
--- @param self ZigbeeDriver The current driver running containing necessary context for execution
--- @param device st.zigbee.Device The device this message was received from containing identifying information
local function do_configure(self, device)
  device.log.trace("do_configure()")

  NeedsRefresh = true

   -- Additional one time configuration
  retrieve_power_divisors(self, device)

  -- Until the power divisor values are retrieved, requesting power/voltage/current status is considered
  -- invalid.  

  -- Force update of all preferences to sync with the device
  updatePreferences(self, device)
end

-- lifecycle 'driverSwitched' handler
-- Called when a device object is being switched to an already included
-- device.   For powered devies, this can run the same logic as
-- the doConfigure action.   For sleepy devices the radio may be offline
-- and the configuration of the device will need to be scheduled.
-- Called after init.
--- @param self ZigbeeDriver The current driver running containing necessary context for execution
--- @param device st.zigbee.Device The device this message was received from containing identifying information
local function do_driverSwitched(self, device, event, args)
  device.log.trace("do_driverSwitched()")

  call_parent_handler(self.lifecycle_handlers.driverSwitched, self, device, event, args)

  NeedsRefresh = true

   -- Additional one time configuration
  retrieve_power_divisors(self, device)

  -- Until the power divisor values are retrieved, requesting power/voltage/current status is considered
  -- invalid.  

  -- Force update of all preferences to sync with the device
  updatePreferences(self, device)
end

--- Handle preference changes
--- @param self ZigbeeDriver The current driver running containing necessary context for execution
--- @param device st.zigbee.Device The device this message was received from containing identifying information
--- @param event table
--- @param args
local function do_removed(self, device, event, args)
  device.log.trace("do_removed() " .. tostring(event))

  call_parent_handler(self.lifecycle_handlers.removed, self, device, event, args)

  -- The device has been removed or changed to another driver.
  -- We should invalidate any fields that would no longer be valid if we switch back to this driver
  clear_divisor_keys(device)
end

-- Return a safe-to-print string/value
local function safeprint(input)
  if type(input) == "table" then
    return utils.stringify_table(input)
  elseif type(input) == "nil" then
    return "(nil)"
  end
  return input
end

--- Handle preference changes
--- @param self ZigbeeDriver The current driver running containing necessary context for execution
--- @param device st.zigbee.Device The device this message was received from containing identifying information
--- @param event table
--- @param args
local function do_infoChanged(self, device, event, args)
  device.log.trace("do_infoChanged() entering " .. tostring(event) )

  -- Test code to get attribute values
  --device:send(Basic.attributes.ApplicationVersion:read(device))
  --device:send(Basic.attributes.HWVersion:read(device))
  --device:send(Basic.attributes.SWBuildID:read(device))
  --device:send(Basic.attributes.ManufacturerVersionDetails:read(device))
  --device:send(Basic.attributes.DateCode:read(device))
  --device:send(Basic.attributes.ProductCode:read(device))
  --device:send(Basic.attributes.ZCLVersion:read(device))

  -- Update any updated preferences
  -- Note that when called on initial add, our current preferences and previous
  -- st_store preferences are identical
  updatePreferences(self, device, args)
end

local function update_reporting_and_configure_device(self, device)
  -- Now that divisors are sync'ed wwe can setup the device's attribute reporting tables with 
  -- the current value.
  configure_reporting(self, device, device.preferences['powerInterval'], device.preferences['powerIntervalMax'])

  if NeedsRefresh then
    device.log.trace("Requesting pending refresh()")
    NeedsRefresh = false
    device.thread:queue_event(self.lifecycle_dispatcher.dispatch, self.lifecycle_dispatcher, self, device, "deviceRefresh")
    -- device:refresh()
  end
  -- Send ReportConfigs for any of our configured attributes on this device
  device.thread:queue_event(self.lifecycle_dispatcher.dispatch, self.lifecycle_dispatcher, self, device, "deviceConfigure")
  -- device:configure()
end

--- @param self ZigbeeDriver The current driver running containing necessary context for execution
--- @param device st.zigbee.Device The device this message was received from containing identifying information
--- @param event table
--- @param args
local function do_configureReporting(self, device, event, args)
  device.log.trace("do_configureReporting()")
  if are_divisors_synced(device) then
    device.log.debug("All synced.  Setting up reporting")
    update_reporting_and_configure_device(self, device)
  elseif args.attempts_remaining > 0 then
    device.log.debug("Rescheduling reporting, remaining attempts: " .. tostring(args.attempts_remaining) )
    args.attempts_remaining = args.attempts_remaining - 1

    local delayed_reporting = function (d)
      device.thread:queue_event(self.lifecycle_dispatcher.dispatch, self.lifecycle_dispatcher, self, device, "configureReporting", args)
    end

    device.thread:call_with_delay(3, delayed_reporting, "delayed configure reporting")
  else
    -- Divisors haven't been received, but we've run out of time.
    -- So just configure_reporting with the defaults
    device.log.warn("Updated divisors not available. Using defaults.")
    update_reporting_and_configure_device(self, device)
  end
end

--- @param self ZigbeeDriver The current driver running containing necessary context for execution
--- @param device st.zigbee.Device The device this message was received from containing identifying information
local function do_deviceRefresh(self, device)
  device.log.trace("do_deviceRefresh()")
  device:refresh()
end

--- @param self ZigbeeDriver The current driver running containing necessary context for execution
--- @param device st.zigbee.Device The device this message was received from containing identifying information
local function do_deviceConfigure(self, device)
  device.log.trace("do_deviceConfigure()")
  device:configure()
end

-- Zigbee attribute handlers
--- @param driver ZigbeeDriver The current driver running containing necessary context for execution
--- @param device st.zigbee.Device The device this message was received from containing identifying information
--- @param zb_rx st.zigbee.ZigbeeMessageRx the full message this report came in
local function active_power_meter_handler(driver, device, value, zb_rx)
  local raw_value = value.value

  if not are_divisors_synced(device) then
    device.log.warn("Warning, received power meter value without correct scaling information.")
  end

  local divisors = get_divisor_data(device)

  -- Only process if we have our multiplier/divisors
  if (divisors.power_multiplier and divisors.power_divisor) then
    raw_value = raw_value * divisors.power_multiplier / divisors.power_divisor

    -- ST shows the values on the display as with 1 decimal place
    -- 115.7W, so lets round values to the same "precision".
    raw_value = round(raw_value, 1)

    device:emit_event(capabilities.powerMeter.power({value = raw_value, unit = "W"}))
  end
end

--- @param driver ZigbeeDriver The current driver running containing necessary context for execution
--- @param device st.zigbee.Device The device this message was received from containing identifying information
--- @param zb_rx st.zigbee.ZigbeeMessageRx the full message this report came in
local function active_voltage_meter_handler(driver, device, value, zb_rx)
  local raw_value = value.value

  if not are_divisors_synced(device) then
    device.log.warn("Warning, received voltage meter value without correct scaling information.")
  end

  local divisors = get_divisor_data(device)

  -- Only process if we have our multiplier/divisors
  if (divisors.voltage_multiplier and divisors.voltage_divisor) then
    raw_value = raw_value * divisors.voltage_multiplier / divisors.voltage_divisor

    -- Round to just a single decimal place
    raw_value = round(raw_value, 1)

    device:emit_event(capabilities.voltageMeasurement.voltage({value = raw_value, unit = "V"}))
  end
end

--- @param driver ZigbeeDriver The current driver running containing necessary context for execution
--- @param device st.zigbee.Device The device this message was received from containing identifying information
--- @param divisor st.zigbee.data_types.Uint16 the value of the Divisor
--- @param zb_rx st.zigbee.ZigbeeMessageRx the full message this report came in
local function active_current_meter_handler(driver, device, value, zb_rx)
  local raw_value = value.value

  if not are_divisors_synced(device) then
    device.log.warn("Warning, received current meter value without correct scaling information.")
  end

  local divisors = get_divisor_data(device)

  -- Only process if we have our multiplier/divisors
  if (divisors.current_multiplier and divisors.current_divisor) then
    raw_value = raw_value * divisors.current_multiplier / divisors.current_divisor

    -- The range of current would be 0.1 - 15A.
    -- We'll round to 1 decimal place as thats the range thats reasonable.
    raw_value = round(raw_value, 1)

    device:emit_event(capabilities.currentMeasurement.current({value = raw_value, unit = "A"}))
  end
end

--- Default handler for ACPowerDivisor attribute on ElectricalMeasurement cluster
---
--- This will take the Uint16 value of the ACPowerDivisor on the ElectricalMeasurement cluster and set the devices field
--- constants.VOLTAGE_MEASUREMENT_DIVISOR_KEY to the value.  This will then be used in the default handling of the
--- ActivePower attribute
---
--- @param driver ZigbeeDriver The current driver running containing necessary context for execution
--- @param device st.zigbee.Device The device this message was received from containing identifying information
--- @param divisor st.zigbee.data_types.Uint16 the value of the Divisor
--- @param zb_rx st.zigbee.ZigbeeMessageRx the full message this report came in
local function voltage_measurement_divisor_handler(driver, device, divisor, zb_rx)
  local raw_value = divisor.value
  device:set_field(constants.VOLTAGE_MEASUREMENT_DIVISOR_KEY, raw_value, {persist = true})
end

--- Default handler for ACPowerMultiplier attribute on ElectricalMeasurement cluster
---
--- This will take the Uint16 value of the ACPowerMultiplier on the ElectricalMeasurement cluster and set the devices field
--- constants.ELECTRICAL_MEASUREMENT_MULTIPLIER_KEY to the value.  This will then be used in the default handling of the
--- ActivePower attribute
---
--- @param driver ZigbeeDriver The current driver running containing necessary context for execution
--- @param device st.zigbee.Device The device this message was received from containing identifying information
--- @param multiplier st.zigbee.data_types.Uint16 the value of the Divisor
--- @param zb_rx st.zigbee.ZigbeeMessageRx the full message this report came in
local function voltage_measurement_multiplier_handler(driver, device, multiplier, zb_rx)
  local raw_value = multiplier.value
  device:set_field(constants.VOLTAGE_MEASUREMENT_MULTIPLIER_KEY, raw_value, {persist = true})
end

--- Default handler for ACPowerDivisor attribute on ElectricalMeasurement cluster
---
--- This will take the Uint16 value of the ACPowerDivisor on the ElectricalMeasurement cluster and set the devices field
--- constants.ELECTRICAL_MEASUREMENT_DIVISOR_KEY to the value.  This will then be used in the default handling of the
--- ActivePower attribute
---
--- @param driver ZigbeeDriver The current driver running containing necessary context for execution
--- @param device st.zigbee.Device The device this message was received from containing identifying information
--- @param divisor st.zigbee.data_types.Uint16 the value of the Divisor
--- @param zb_rx st.zigbee.ZigbeeMessageRx the full message this report came in
local function current_measurement_divisor_handler(driver, device, divisor, zb_rx)
  local raw_value = divisor.value
  device:set_field(constants.CURRENT_MEASUREMENT_DIVISOR_KEY, raw_value, {persist = true})
end

--- Default handler for ACPowerMultiplier attribute on ElectricalMeasurement cluster
---
--- This will take the Uint16 value of the ACPowerMultiplier on the ElectricalMeasurement cluster and set the devices field
--- constants.ELECTRICAL_MEASUREMENT_MULTIPLIER_KEY to the value.  This will then be used in the default handling of the
--- ActivePower attribute
---
--- @param driver ZigbeeDriver The current driver running containing necessary context for execution
--- @param device st.zigbee.Device The device this message was received from containing identifying information
--- @param multiplier st.zigbee.data_types.Uint16 the value of the Divisor
--- @param zb_rx st.zigbee.ZigbeeMessageRx the full message this report came in
local function current_measurement_multiplier_handler(driver, device, multiplier, zb_rx)
  local raw_value = multiplier.value
  device:set_field(constants.CURRENT_MEASUREMENT_MULTIPLIER_KEY, raw_value, {persist = true})
end

--- @param driver st.zwave.Driver
--- @param device st.zwave.Device
--- @param command table The capability command table
local function lockout_protect_switch_off(driver, device, command)
  if not device.preferences.turnoffLockout then
    -- Forward on to the default handler
    local handlers = driver.capability_handlers[capabilities.switch.ID][capabilities.switch.commands.off.NAME]
    call_parent_handler(handlers, driver, device, command)
  else
    device.log.warn("Lockout enabled.  Ignoring Off request.")
    -- read the on off state to make the UI refresh
    device:send(clusters.OnOff.attributes.OnOff:read(device))
  end
end

-- subdriver template
local peanut_plug = {
  NAME = "Peanut Plug",   -- name used for debug and error output
  --   supported_capabilities = { }
  zigbee_handlers = {
    attr = {    -- 'attr' handlers map ReadAttributeResponse to cluster/attributes
      [ElectricalMeasurement.ID] = {
        [ElectricalMeasurement.attributes.ActivePower.ID] = active_power_meter_handler,

        [ElectricalMeasurement.attributes.ACVoltageDivisor.ID] = voltage_measurement_divisor_handler,
        [ElectricalMeasurement.attributes.ACVoltageMultiplier.ID] = voltage_measurement_multiplier_handler,
        [ElectricalMeasurement.attributes.RMSVoltage.ID] = active_voltage_meter_handler,

        [ElectricalMeasurement.attributes.ACCurrentDivisor.ID] = current_measurement_divisor_handler,
        [ElectricalMeasurement.attributes.ACCurrentMultiplier.ID] = current_measurement_multiplier_handler,
        [ElectricalMeasurement.attributes.RMSCurrent.ID] = active_current_meter_handler
      },
    }
  },
  
  capability_handlers = {
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.off.NAME] = lockout_protect_switch_off
    },
  },
  -- driver_lifecycle =
  lifecycle_handlers = {
    init             = do_init,       -- initialization function
    -- added =
    doConfigure      = do_configure,  -- Override zigbee's default doConfigure
    infoChanged      = do_infoChanged,  -- Update preferences on device
    driverSwitched   = do_driverSwitched,  -- Override zigbee's default driverSwitched
    removed          = do_removed,         -- Device has been removed
    
    --- Custom lifecycle events
    configureReporting = do_configureReporting,
    deviceRefresh      = do_deviceRefresh,
    deviceConfigure    = do_deviceConfigure,
  },
  can_handle = can_handle_peanut_plug
}

return peanut_plug