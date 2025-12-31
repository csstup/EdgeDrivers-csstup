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

local capabilities = require "st.capabilities"
local ZigbeeDriver = require "st.zigbee"
local defaults = require "st.zigbee.defaults"
local constants = require "st.zigbee.constants"
local zb_messages = require "st.zigbee.messages"

-- Zigbee Clusters
local zcl_clusters = require "st.zigbee.zcl.clusters"
local IASZone = zcl_clusters.IASZone
local PollControl = zcl_clusters.PollControl

-- Utilties
local buf_lib = require "st.buf"
local log = require "log"

local SignalStrength = capabilities.signalStrength

local configurationMap = require "configurations"

local LATEST_SIGNAL_UPDATE_TIMESTAMP = "latest_signal_update_timestamp"
local SIGNAL_UPDATE_INTERVAL_SEC = 60   -- Update signal strength no more than every 60 seconds

-- init function 
-- This function will be called any time a device object needs
--  to be instantiated within the driver. There are 2 main cases where this happens: 
--     1) the driver just started up and needs to create the objects for existing devices and
--     2) a device was newly added to the driver.
local function device_init(driver, device)
  device.log.trace("device_init() enter")
  local configuration = configurationMap.get_device_configuration(device)

  if configuration then
    for _, config in ipairs(configuration) do
      if (config.cluster) then
        -- Add this cluster/attribute as configured.  The system will automatically
        -- setup any configured attribute as ConfigureReport during doConfigure().
        -- Note that we do NOT mark these as monitored, as this device sleeps 
        -- for 5 minutes between long polls, so it would not hear any 
        -- ReadRequest for a timed out attribute.
        device:add_configured_attribute(config)
      end
    end
  end

  -- We're now removing the IAS attributes via a cluster configuration
  --       in the template.
  -- log.info("Removing IAS Zone configured attribute")
  -- device:remove_configured_attribute(IASZone.ID, IASZone.attributes.ZoneStatus.ID)
  -- device:remove_monitored_attribute(IASZone.ID, IASZone.attributes.ZoneStatus.ID)

  -- Set the battery type/quantity.   We do it in init because we want to set it for 
  -- all devices, not just newly added ones.
  device:emit_event(capabilities.battery.quantity(2))
  device:emit_event(capabilities.battery.type("AAA"))

  device.log.trace("device_init() leave")
end

local function seconds_since_latest_signal_update(device)
  local last_time = device:get_field(LATEST_SIGNAL_UPDATE_TIMESTAMP)
  if last_time ~= nil then
      return os.difftime(os.time(), last_time)
  end
  return SIGNAL_UPDATE_INTERVAL_SEC + 1
end

local function emit_signal_strength_events(device, zb_rx)
  if seconds_since_latest_signal_update(device) > SIGNAL_UPDATE_INTERVAL_SEC then
    device:set_field(LATEST_SIGNAL_UPDATE_TIMESTAMP, os.time())
    device:emit_event(SignalStrength.lqi(zb_rx.lqi.value))
    device:emit_event(SignalStrength.rssi({value = zb_rx.rssi.value, unit = 'dBm'}))
  end
end

--
-- Poll Control checkin handler
-- 
local function poll_control_checkin_handler(self, device, zb_rx)
  device.log.trace("poll_control_checkin_handler()")
  -- Is there anything to do?

  if (device:get_field("init_complete") == nil) then
    -- Yes, tell the device to go into FastPollMode, as we're going to communicate with it.
    device:send(zcl_clusters.PollControl.commands.CheckInResponse(device, true, 0))

    device:set_field("init_complete", true)
    -- Send a read attribute command for all configured attributes on this device
    device:refresh()

    -- Tell the device we're done and it can stop fast polling now.
    device:send(zcl_clusters.PollControl.commands.FastPollStop(device))
  else
    -- Tell the sensor we have nothing for it, don't bother going into FastPollMode
    -- Note: Sending the CheckInResponse(false) message the device returns an ERROR.
    --  my guess is that it just doesn't go into fast poll mode, goes back to idle.
    -- device:send(zcl_clusters.PollControl.commands.CheckInResponse(device, false, 0))
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
--local zcl_global_commands  = require "st.zigbee.zcl.global_commands"
local zigbee_water_driver_template = {
  supported_capabilities = {
    capabilities.waterSensor,
    capabilities.signalStrength,
    capabilities.voltageMeasurement,
    capabilities.battery,       --  Battery is always shown last on the detail view anyway
  },
  cluster_configurations = {
    [capabilities.waterSensor.ID] = {  -- try and remove any default attributes (IAS included) from the capabilities
      { 
        cluster   = IASZone.ID,
        attribute = IASZone.attributes.ZoneStatus.ID,
        monitored = false,
        configurable = false,
      }
    }
  },
  zigbee_handlers = {
    -- attr = {}   -- 'attr' maps attribute read response
    -- global = {} -- 'global' is for any non cluster specific commands.
    cluster = {    -- 'cluster' is for cluster specific command handling
      [PollControl.ID] = {
        [PollControl.commands.CheckIn.ID] = poll_control_checkin_handler
      }
    }
  },
  lifecycle_handlers = {
    init = device_init
    -- added = 
    -- doConfigure =     -- Zigbee has a doConfigure default
    -- infoChanged = 
    -- driverSwitched =  -- Zigbee has a driverSwitched default
    -- removed =  
  },
  ias_zone_configuration_method = constants.IAS_ZONE_CONFIGURE_TYPE.AUTO_ENROLL_RESPONSE,
  -- Custom handler for every Zigbee message
  zigbee_message_handler = all_zigbee_message_handler,

  -- We don't want any of our attributes monitored by the old health check system
  health_check = false,

  sub_drivers = {
    require("linkind"),
  },
  -- driver_lifecycle =
}

-- Register the defaults based on capabilities in our template and the sub drivers.
defaults.register_for_default_handlers(zigbee_water_driver_template, zigbee_water_driver_template.supported_capabilities)
local zigbee_water_driver = ZigbeeDriver("zigbee-water", zigbee_water_driver_template)
zigbee_water_driver:run()
