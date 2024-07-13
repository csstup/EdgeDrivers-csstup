-- Copyright 2024 SmartThings
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
--- @type st.zwave.CommandClass
local cc = require "st.zwave.CommandClass"
--- @type st.zwave.CommandClass.Basic
local Basic = (require "st.zwave.CommandClass.Basic")({ version=1 })
--- @type st.zwave.CommandClass.Battery
local Battery = (require "st.zwave.CommandClass.Battery")({ version = 1 })
--- @type st.zwave.CommandClass.Notification
local Notification = (require "st.zwave.CommandClass.Notification")({ version = 3 })
--- @type st.zwave.CommandClass.Configuration
local Configuration = (require "st.zwave.CommandClass.Configuration")({ version=4 })
--- @type st.zwave.CommandClass.SoundSwitch
local SoundSwitch = (require "st.zwave.CommandClass.SoundSwitch")({ version=1 })
--- @type st.utils
local utils = require "st.utils"
local call_parent_handler = require "call_parent"

local LAST_BATTERY_REPORT_TIME = "lastBatteryReportTime"

local ZOOZ_FINGERPRINTS = {
  { manufacturerId = 0x027A, productType = 0x000C, productId = 0x0003 }, --- Zooz ZSE19 S2 Multisiren
}

---
--- @param driver st.zwave.Driver
--- @param device st.zwave.Device
--- @return boolean true if the device proper, else false
local function can_handle_zooz_siren(opts, driver, device, ...)
  for _, fingerprint in ipairs(ZOOZ_FINGERPRINTS) do
    if device:id_match(fingerprint.manufacturerId, fingerprint.productType, fingerprint.productId) then
      return true
    end
  end
  return false
end

--- @param self st.zwave.Driver
--- @param device st.zwave.Device
--- @param cmd st.zwave.CommandClass.Battery.Report
local function battery_report(self, device, cmd)
  -- Save the timestamp of the last battery report received.
  device:set_field(LAST_BATTERY_REPORT_TIME, os.time(), { persist = true } )
  if cmd.args.battery_level == 99 then cmd.args.battery_level = 100 end
  if cmd.args.battery_level == 0xFF then cmd.args.battery_level = 1 end
  -- Forward on to the default battery report handlers from the top level
  call_parent_handler(self.zwave_handlers[cc.BATTERY][Battery.REPORT], self, device, cmd)
end

--- @param self st.zwave.Driver
--- @param device st.zwave.Device
--- @param cmd st.zwave.CommandClass.Notification.Report
local function notification_handler(self, device, cmd)
  local home_security_notification_events_map = {
    [Notification.event.home_security.TAMPERING_PRODUCT_COVER_REMOVED] = capabilities.tamperAlert.tamper.detected(),
    [Notification.event.home_security.TAMPERING_INVALID_CODE] = capabilities.tamperAlert.tamper.detected(),
    [Notification.event.home_security.TAMPERING_PRODUCT_MOVED] = capabilities.tamperAlert.tamper.detected(),
    [Notification.event.home_security.STATE_IDLE] = capabilities.tamperAlert.tamper.clear(),
  }

  -- For tamper type events (HOME SECURITY) we handle it directly here, as the default alarm capability
  -- handler will also handle this case as an ALARM condition.
  -- For all other NOTIFICATION events, forward to the top level as if we didn't exist.
  if (cmd.args.notification_type == Notification.notification_type.HOME_SECURITY) then
    device.log.debug("handling tamper notification result manually")
    local event = home_security_notification_events_map[cmd.args.event]
    if event then
      device:emit_event_for_endpoint(cmd.src_channel, event)
    end
  else
    device.log.debug("forwarding all other notification results")
    call_parent_handler(self.zwave_handlers[cc.NOTIFICATION][Notification.REPORT], self, device, cmd)
  end
end


local function request_tone_playback(self, device, tone)
    -- Convert the tone into a number to be sure its sent correctly.
    -- Must be 0-100.
    -- Now play the tone
    -- device:send(Configuration:Set({parameter_number = 3, size = 1, configuration_value = tone}))
    device:send(SoundSwitch:TonePlaySet({tone_identifier = tone}))

end

--- @param driver st.zwave.Driver
--- @param device st.zwave.Device
local function do_beep(driver, device)

  -- Make sure the alarm isn't being triggered currently
  local alarm_state = device:get_latest_state('main', capabilities.alarm.ID, 'alarm')

  if alarm_state == 'off' then
    local tone = device.preferences["toneSound"]
    device.log.info("requesting tone sound " .. tone)

    if tone ~= 0 then
        request_tone_playback(driver, device, tone)
    end
  else
    device.log.warn("alarm is currently triggered.  ignoring tone request.")
  end
end

--- @param driver st.zwave.Driver
--- @param device st.zwave.Device
local function set_level(driver, device, command)

    local level = utils.round(command.args.level)
    level = utils.clamp_value(level, 0, 99)

    device.log.info("Dimmer level = " .. level)

    request_tone_playback(driver, device, level)

    local reset_level = function()
      device.log.info("resetting level to 100")
      device:emit_event(capabilities.switchLevel.level(100))
    end

    -- Then reset the dimmer level to 100% once we've requested it
    device.thread:call_with_delay(2, reset_level)
end

--- @param driver st.zwave.Driver
--- @param device st.zwave.Device
local function set_volume(driver, device, command)

  local volume = command.args.volume
  device:send(SoundSwitch:ConfigurationSet({volume = volume}))
  device:send(SoundSwitch:ConfigurationGet({}))
end


--- @param driver st.zwave.Driver
--- @param device st.zwave.Device
local function device_added(driver, device)

  -- Set the initial values for the capabilities
  device:emit_event(capabilities.switchLevel.level(100))
  device:emit_event(capabilities.tamperAlert.tamper.clear())
  device:emit_event(capabilities.audioVolume.volume(100))

  device:refresh()
end

--- @param self st.zwave.Driver
--- @param device st.zwave.Device
--- @param cmd st.zwave.CommandClass.SoundSwitch.ConfigurationReport
local function soundSwitch_config_report(driver, device, cmd)
  local volume = cmd.args.volume
  device:emit_event(capabilities.audioVolume.volume(volume))
end

local zooz_siren = {
  zwave_handlers = {
    [cc.BATTERY] = {
      [Battery.REPORT] = battery_report,
    },
    [cc.NOTIFICATION] = {
      [Notification.REPORT] = notification_handler, 
    },
    [cc.SOUND_SWITCH] = {
      [SoundSwitch.CONFIGURATION_REPORT] = soundSwitch_config_report,
    }
  },
  capability_handlers = {
    [capabilities.tone.ID] = {
        [capabilities.tone.commands.beep.NAME] = do_beep
    },
    [capabilities.switchLevel.ID] = {
        [capabilities.switchLevel.commands.setLevel.NAME] = set_level,
    },
    [capabilities.audioVolume.ID] = {
			[capabilities.audioVolume.commands.setVolume.NAME] = set_volume,
		},
    
  },
  lifecycle_handlers = {
    added = device_added,
  }, 
  NAME = "zooz siren",
  can_handle = can_handle_zooz_siren
}

return zooz_siren