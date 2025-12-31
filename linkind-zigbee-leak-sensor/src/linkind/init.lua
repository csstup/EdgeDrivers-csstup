-- Linkind Leak Sensor
-- 
-- Model on the device itself is "LS21001", but the device reports its model as "A001082".
--
-- To pair this device, press and hold the button for 5+ seconds until the LED blinks quickly.  
-- Release the button, the LED will blink slowly indicating its ready to pair.
--
-- Leak sensor only.  No temperature or humidity. 
-- Uses 2 AAA sized batteries
-- Has a 90db built in siren when a alarm condition is detected
-- Checkin interval is 0x54600 qtr seconds (24 hours)
-- Long poll checkins are set to every 1200 qtr-seconds (5 minutes).
-- It will flash the LED with Identify (cluster 0x0003) commads 
--
-- Status updates:
-- The device returns IAS Zone Status bits 4 and 5 (0x30) SET to indicate:
--  bit 4 - Supervision reports (set = enabled).  The device will periodically
--          (testing shows every 2 hours) send a IASZoneStatusChangeNotification when not faulted, 
--          and every 5 minutes when faulted (leak detected).
--          with the current status.  We can use this as a device checkin.
--  bit 5 - Restore reports (set = restore).  The device will send a notification
--          when the zone status is cleared (ie, returns to dry state.)
--
-- Water events:
--  Registers as an IAS device.    Water events are sent as an IASZoneStatusChangeNotification for alarm 1.
--
-- Battery updates:
--   The device allows for setting a report frequency for both battery voltage and battery percentage.  By default
--   the reporting is disabled (no unsolicited battery reports).
-- 
-- From Linkind support:
--  【Optional Alarm Methods】- Each water leak detector features 4 work modes,
--    which you can selsect in Linkind APP.
--    Mode 1: Not alarming_no LED flashing; 
--    Mode 2: Not alarming_LED flashing; 
--    Mode 3: Alarming_no LED flashing; 
--    Mode 4: Alarming_LED flashing (NOTE: works via Linkind hub to Linkind APP).
-- 
--  Mode 4 is the default, and not sure how to change the mode currently.

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

local device_management = require "st.zigbee.device_management"

-- Capabilities
local capabilities = require "st.capabilities"

-- Zigbee Clusters
local zcl_clusters = require "st.zigbee.zcl.clusters"
local Basic = zcl_clusters.Basic
local PowerConfiguration = zcl_clusters.PowerConfiguration -- 0x0001
local PollControl = zcl_clusters.PollControl   -- 0x0020

-- Utility 
local log = require "log"

local LINKIND_WATER_LEAK_SENSOR_FINGERPRINTS = {
  { mfr = "LK", model = "A001082" },
}

local function can_handle_linkind_reality_water_leak_sensor(opts, driver, device)
  for _, fingerprint in ipairs(LINKIND_WATER_LEAK_SENSOR_FINGERPRINTS) do
    if device:get_manufacturer() == fingerprint.mfr and device:get_model() == fingerprint.model then
      return true
    end
  end
  return false
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
--   event: driverSwitched
--   capability: Refresh called, runs command refresh
-- On device re-pairing (existing device)
--   event: infoChanged (parallel with doConfigure)
--   event: doConfigure 

local function do_init(self, device)
end


-- lifecycle 'doConfigure' handler
-- Called when a device object needs to be instantiated within the driver.
--- 1) the driver just started up and needs to create the objects for existing devices and
--- 2) a device was newly added to the driver.
-- We do any actions here both for newly added devices AND after reboot. 
-- We don't send any data to the device as the zigbee radio may not be ready (in the case of reboot)
--  or sleepy devices may not be listening anyway.
local function do_configure(self, device)
  device.log.trace("do_configure() enter")

  device:set_field("init_complete", true)

  -- Send ReportConfigs for any of our configured attributes on this device
  device:configure()

  -- Send a read attribute command for all configured attributes on this device
  device:refresh()

  -- Read some of the basic attributes that we don't monitor
  device:send(Basic.attributes.DateCode:read(device))  -- 0x0008
  device:send(Basic.attributes.SWBuildID:read(device)) -- 0x4000

  -- This device has a default long poll interval of 5 minutes.
  -- device:send(PollControl.attributes.LongPollInterval:read(device))
  -- device:send(PollControl.attributes.LongPollIntervalMin:read(device))


  -- CSS TODO:
  -- This really doesn't do what we want, since its only run when the
  -- device is configured (during initial pairing).   
  -- I'm not sure if this survives reboots (battery cycles) of the device
  -- or not.

  -- This device has a default checkin interval of 24 hours
  -- and a checkin interval minimum of 1 hour.
  -- Because we're not using any sort of preferences that need
  -- syncing on checkin, we don't
  -- really bother setting checkin to something else.  Saves battery.
  if device:supports_server_cluster(PollControl.ID) then
    device:send(PollControl.attributes.CheckInIntervalMin:read(device))

    -- device:send(PollControl.attributes.FastPollTimeout:read(device))
    -- device:send(PollControl.attributes.FastPollTimeoutMax:read(device))
  
    -- Set the checkin interval to a more reasonable value (0x3840 = 1 hour in qtr seconds)
    device:send(device_management.build_bind_request(device, PollControl.ID, self.environment_info.hub_zigbee_eui))
    device:send(PollControl.attributes.CheckInInterval:write(device, 0x3840 ))  --  
    -- device:send(PollControl.attributes.CheckInInterval:read(device))
  end

  device.log.trace("do_configure() leave")
end

-- Zigbee attribute handlers
local function battery_voltage_handler(driver, device, value, zb_rx)
  -- We override the battery voltage handler to generate a voltageMeasurement capability.
  -- This is how we show both battery % and voltage.
  device.log.info("battery voltage handler: " .. value.value)
  -- TODO: Figure out how to force padding
  -- local paddedValue = string.format("%2.1f", value.value/10)
  -- [string "st/capabilities/init.lua"]:226: Value 3.0 is invalid for Voltage Measurement.voltage
  -- TODO:
  --  adjust the battery voltage display on the detail panel to be between 2.5 and 3.0
  --  the device reports its min battery voltage min threshold to be 2.5V.
  device:emit_event(capabilities.voltageMeasurement.voltage({value = value.value/10, unit = 'V'}))
end

local function basic_datecode_handler(driver, device, value, zb_rx)
  device.log.info("basic_datecode_handler: " .. value.value)
end

local function basic_swbuildid_handler(driver, device, value, zb_rx)
  device.log.info("basic_swbuildid_handler: " .. value.value)
end

-- subdriver template
local linkind_water_leak_sensor = {
  NAME = "Linkind leak sensor",   -- name used for debug and error output
  --   supported_capabilities = { }
  zigbee_handlers = {
    attr = {    -- 'attr' handlers map ReadAttributeResponse to cluster/attributes
      [Basic.ID] = {
        [Basic.attributes.DateCode.ID]  = basic_datecode_handler,
        [Basic.attributes.SWBuildID.ID] = basic_swbuildid_handler
      },
      [PowerConfiguration.ID] = {
        [PowerConfiguration.attributes.BatteryVoltage.ID] = battery_voltage_handler
      }
    }
  },
  -- capability_handlers = {}
  -- driver_lifecycle =
  lifecycle_handlers = {
    -- init = do_init,
    -- added =
    doConfigure = do_configure,  -- Override zigbee's default doConfigure
    -- infoChanged = 
    -- driverSwitched =
    -- removed =  
  },
  can_handle = can_handle_linkind_reality_water_leak_sensor
}

return linkind_water_leak_sensor