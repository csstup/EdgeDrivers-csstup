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

local ZigbeeDriver = require "st.zigbee"
local defaults = require "st.zigbee.defaults"
local constants = require "st.zigbee.constants"
local zb_messages = require "st.zigbee.messages"

-- Zigbee Clusters
local clusters = require "st.zigbee.zcl.clusters"
local ElectricalMeasurement = clusters.ElectricalMeasurement

-- Utilties
local buf_lib = require "st.buf"
local log = require "log"
local utils = require("st.utils")

-- Capabilities
local capabilities = require "st.capabilities"
local SignalStrength = capabilities.signalStrength

local LATEST_SIGNAL_UPDATE_TIMESTAMP = "latest_signal_update_timestamp"
local SIGNAL_UPDATE_INTERVAL_SEC = 60   -- Update signal strength no more than every 60 seconds

-- init function 
-- This function will be called any time a device object needs
--  to be instantiated within the driver. There are 2 main cases where this happens: 
--     1) the driver just started up and needs to create the objects for existing devices and
--     2) a device was newly added to the driver.
local function device_init(driver, device)
  device.log.trace("device_init()")

  -- Remove the configured attribute added by the defaults
  device:remove_configured_attribute(ElectricalMeasurement.ID, ElectricalMeasurement.attributes.ActivePower.ID)
  device:remove_monitored_attribute(ElectricalMeasurement.ID, ElectricalMeasurement.attributes.ActivePower.ID)

  -- print (utils.stringify_table(device:get_field("__configured_attributes"), "default cluster_configurations:", true))
end

local function seconds_since_latest_signal_update(device)
  local last_time = device:get_field(LATEST_SIGNAL_UPDATE_TIMESTAMP)
  if last_time ~= nil then
      return os.difftime(os.time(), last_time)
  end
  return SIGNAL_UPDATE_INTERVAL_SEC + 1
end

local function emit_signal_strength_events(device, zb_rx)
  local visible_state = device.preferences.signalHistory or false

  if seconds_since_latest_signal_update(device) > SIGNAL_UPDATE_INTERVAL_SEC then
    device:set_field(LATEST_SIGNAL_UPDATE_TIMESTAMP, os.time())
    device:emit_event(SignalStrength.lqi({ value = zb_rx.lqi.value}, {visibility = {displayed = visible_state }}))
    device:emit_event(SignalStrength.rssi({value = zb_rx.rssi.value, unit = 'dBm'},  {visibility = {displayed = visible_state }}))
  end
end

-- Hook in to process all messages, pulling signal strength values before passing up the
-- processing queue for higher level message dispatching.
local function all_zigbee_message_handler(self, message_channel)
  local device_uuid, data = message_channel:receive()
  local buf = buf_lib.Reader(data)
  local zb_rx = zb_messages.ZigbeeMessageRx.deserialize(buf, {additional_zcl_profiles = self.additional_zcl_profiles})
  local device = self:get_device_info(device_uuid)
  if zb_rx ~= nil then
    device.log.info(string.format("received Zigbee message: %s", zb_rx:pretty_print()))
    device:attribute_monitor(zb_rx)
    if (device:supports_capability_by_id("signalStrength") and zb_rx.rssi.value ~= nil and zb_rx.lqi.value ~= nil) then
      emit_signal_strength_events(device, zb_rx)
    end
    -- poke(device)
    device.thread:queue_event(self.zigbee_message_dispatcher.dispatch, self.zigbee_message_dispatcher, self, device, zb_rx)
  end
end

-- Driver template
local zigbee_peanut_driver_template = {
  supported_capabilities = {
    capabilities.switch,
    capabilities.powerMeter,           -- 'power' attribute
    capabilities.voltageMeasurement,   -- 'voltage' attribute
    capabilities.currentMeasurement,   -- 'current' attribute
    capabilities.signalStrength,
    capabilities.firmwareUpdate,
    capabilities.refresh,
  },
  zigbee_handlers = {
    -- attr = {}   -- 'attr' maps to attribute read response handlers
    -- global = {} -- 'global' is for any non cluster specific commands.
    -- cluster = {    -- 'cluster' is for cluster specific command handling
   --   [PollControl.ID] = {
   --     [PollControl.commands.CheckIn.ID] = poll_control_checkin_handler
   --   }
   -- }
  },
  lifecycle_handlers = {
    init = device_init
    -- added = 
    -- doConfigure =     -- Zigbee has a doConfigure default
    -- infoChanged = 
    -- driverSwitched =  -- Zigbee has a driverSwitched default
    -- removed =  
  },
  -- Custom handler for every Zigbee message
   zigbee_message_handler = all_zigbee_message_handler,

  sub_drivers = {
    require("peanut-plug"),
  },
  -- driver_lifecycle =
}

-- Register the defaults based on capabilities in our template and the sub drivers.
defaults.register_for_default_handlers(zigbee_peanut_driver_template, zigbee_peanut_driver_template.supported_capabilities)
-- log.info("Default table: " .. utils.stringify_table(zigbee_peanut_driver_template) )
local peanut_plug_driver = ZigbeeDriver("peanut-plug", zigbee_peanut_driver_template)
peanut_plug_driver:run()
