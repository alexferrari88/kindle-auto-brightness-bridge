-- luacheck: globals G_reader_settings

local Device = require("device")
local logger = require("logger")
local _ = require("gettext")

local SETTING = "kindleautobrightness_enabled"
local WARMTH_SETTING = "kindleautobrightness_warmth_enabled"
local WRAPPER_STATE = "_kindle_auto_brightness_bridge_state"
local WARMTH_WRAPPER_STATE = "_kindle_auto_warmth_bridge_state"
local TOGGLE_WRAPPER_STATE = "_kindle_auto_brightness_toggle_state"

local function valid_intensity(powerd, intensity)
    return type(intensity) == "number"
        and intensity == intensity
        and type(powerd.fl_min) == "number"
        and type(powerd.fl_max) == "number"
        and powerd.fl_min < powerd.fl_max
        and intensity >= powerd.fl_min
        and intensity <= powerd.fl_max
end

local function valid_warmth(warmth)
    return type(warmth) == "number"
        and warmth == warmth
        and warmth >= 0
        and warmth <= 100
end

local function has_capability(device, name)
    local method = device and device[name]
    if type(method) ~= "function" then
        return false
    end
    local ok, value = pcall(method, device)
    return ok and value == true
end

local function get_powerd(device)
    if not device or type(device.getPowerDevice) ~= "function" then
        return nil
    end
    local ok, powerd = pcall(device.getPowerDevice, device)
    if not ok or type(powerd) ~= "table" then
        return nil
    end
    return powerd
end

local function has_live_read(powerd)
    return type(powerd.frontlightIntensityHW) == "function"
end

local function has_warmth_reader(device, powerd)
    return has_capability(device, "hasNaturalLight")
        and type(powerd and powerd.frontlightWarmthHW) == "function"
end

local function has_native_light_sensor(powerd)
    local lipc_handle = powerd and powerd.lipc_handle
    if lipc_handle == nil then
        return false
    end
    local ok, lux = pcall(function()
        return lipc_handle:get_int_property("com.lab126.powerd", "alsLux")
    end)
    return ok and type(lux) == "number" and lux >= 0
end

local capability_powerd = get_powerd(Device)
local has_sensor = has_capability(Device, "hasLightSensor")
    or has_native_light_sensor(capability_powerd)
if not has_capability(Device, "isKindle")
        or not has_capability(Device, "hasFrontlight")
        or not has_sensor
        or not capability_powerd
        or not has_live_read(capability_powerd) then
    return { disabled = true }
end

local WidgetContainer = require("ui/widget/container/widgetcontainer")

local KindleAutoBrightness = WidgetContainer:extend{
    name = "kindleautobrightness",
    settings_key = SETTING,
}

local function read_live_intensity(powerd)
    if type(powerd.frontlightIntensityHW) ~= "function" then
        return nil, "reader unavailable"
    end

    local ok, intensity = pcall(powerd.frontlightIntensityHW, powerd)
    if not ok then
        return nil, "reader error: " .. tostring(intensity)
    end
    if not valid_intensity(powerd, intensity) then
        return nil, "reader returned an invalid intensity"
    end
    return intensity
end

local function read_live_warmth(powerd)
    if type(powerd.frontlightWarmthHW) ~= "function" then
        return nil, "reader unavailable"
    end

    local ok, warmth = pcall(powerd.frontlightWarmthHW, powerd)
    if not ok then
        return nil, "reader error: " .. tostring(warmth)
    end
    if not valid_warmth(warmth) then
        return nil, "reader returned an invalid warmth"
    end
    return warmth
end

local function fallback_intensity(powerd, original_ok, original_result)
    if original_ok and valid_intensity(powerd, original_result) then
        return original_result
    end
    if valid_intensity(powerd, powerd.fl_intensity) then
        return powerd.fl_intensity
    end
    return 0
end

local function observe_intensity(powerd)
    local intensity, read_error = read_live_intensity(powerd)
    if intensity == nil then
        logger.dbg("KindleAutoBrightness: live frontlight read unavailable", read_error)
        return nil
    end
    powerd.is_fl_on = intensity > powerd.fl_min
    -- Off is an observation, never a new remembered restoration level.
    if powerd.is_fl_on then
        powerd.fl_intensity = intensity
    end
    return intensity
end

local function call_original(state, method, this, ...)
    -- BasePowerD's intensity/off methods call the public on/off methods themselves.
    -- Suppress nested observations so one public query uses one hardware sample.
    local was_reading = state.reading
    state.reading = true
    local ok, result = pcall(method, this, ...)
    state.reading = was_reading
    return ok, result
end

local function make_state_wrapper(state, method, is_off_query)
    return function(this, ...)
        if not state.active then return method(this, ...) end
        if not state.reading and not state.toggling then
            local intensity = observe_intensity(this)
            if intensity ~= nil then
                if is_off_query then return intensity <= this.fl_min end
                return intensity > this.fl_min
            end
        end
        local ok, result = call_original(state, method, this, ...)
        if ok then return result end
        if is_off_query then return not this.is_fl_on end
        return this.is_fl_on
    end
end

local function make_wrapper(state)
    return function(this, ...)
        if not state.active then return state.original_method(this, ...) end
        local original_ok, original_result = call_original(state, state.original_method, this, ...)
        if not original_ok then
            logger.dbg("KindleAutoBrightness: original frontlightIntensity failed", original_result)
        end
        if state.toggling then
            return fallback_intensity(this, original_ok, original_result)
        end
        local intensity = observe_intensity(this)
        if intensity == nil then
            return fallback_intensity(this, original_ok, original_result)
        end
        return intensity > this.fl_min and intensity or 0
    end
end

local function fallback_warmth(powerd, original_ok, original_result)
    if original_ok and valid_warmth(original_result) then
        return original_result
    end
    if valid_warmth(powerd.fl_warmth) then
        return powerd.fl_warmth
    end
    return 0
end

local function make_warmth_wrapper(state)
    return function(this, ...)
        local original_ok, original_result = pcall(state.original_method, this, ...)
        if not original_ok then
            logger.dbg("KindleAutoBrightness: original frontlightWarmth failed", original_result)
        end

        local live_warmth, read_error = read_live_warmth(this)
        if live_warmth == nil then
            logger.dbg("KindleAutoBrightness: live frontlight warmth read unavailable", read_error)
            return fallback_warmth(this, original_ok, original_result)
        end

        this.fl_warmth = live_warmth
        return live_warmth
    end
end

function KindleAutoBrightness:_ensureWrapper()
    local current_powerd = get_powerd(self.device or Device)
    if not current_powerd then
        return false
    end

    local existing = current_powerd[WRAPPER_STATE]
    if existing then
        for name, entry in pairs(existing.methods) do
            if current_powerd[name] ~= entry.wrapper then
                logger.dbg("KindleAutoBrightness: refusing to replace another frontlight wrapper")
                self:_restoreWrapper(current_powerd)
                return false
            end
        end
        if existing.listener.owner.onToggleFrontlight ~= existing.listener.wrapper then
            self:_restoreWrapper(current_powerd)
            return false
        end
        self.powerd = current_powerd
        self.wrapper_state = existing
        return true
    end

    local original_method = current_powerd.frontlightIntensity
    if type(original_method) ~= "function" then
        return false
    end

    local state = {
        active = true,
        original_method = original_method,
        original_raw_method = rawget(current_powerd, "frontlightIntensity"),
    }
    state.wrapper = make_wrapper(state)
    state.methods = {
        frontlightIntensity = {
            original = state.original_raw_method,
            wrapper = state.wrapper,
        },
    }
    for _, name in ipairs({ "isFrontlightOn", "isFrontlightOff" }) do
        local method = current_powerd[name]
        if type(method) == "function" then
            state.methods[name] = {
                original = rawget(current_powerd, name),
                wrapper = make_state_wrapper(state, method, name == "isFrontlightOff"),
            }
        end
    end
    -- Kindle's write coda calls this directly, bypassing the public state queries.
    -- A broken live reader must not throw after a successful user-requested write.
    local original_on_hw = current_powerd.isFrontlightOnHW
    if type(original_on_hw) == "function" then
        state.methods.isFrontlightOnHW = {
            original = rawget(current_powerd, "isFrontlightOnHW"),
            wrapper = function(this, ...)
                if not state.active then return original_on_hw(this, ...) end
                local intensity = read_live_intensity(this)
                if intensity ~= nil then return intensity > this.fl_min end
                return this.is_fl_on
            end,
        }
    end
    local listener = require("device/devicelistener")
    local hook = rawget(listener, TOGGLE_WRAPPER_STATE)
    if not hook or listener.onToggleFrontlight ~= hook.wrapper then
        if hook then hook.active = false end
        local original_toggle = listener.onToggleFrontlight
        hook = {
            active = true,
            owner = listener,
            original = rawget(listener, "onToggleFrontlight"),
        }
        hook.wrapper = function(this, ...)
            local powerd = get_powerd(Device)
            local current_state = powerd and powerd[WRAPPER_STATE]
            if not hook.active or not current_state or not current_state.active then
                return original_toggle(this, ...)
            end
            local was_toggling = current_state.toggling
            if not was_toggling then observe_intensity(powerd) end
            -- Notification selection and the toggle guards share the entry state.
            -- Core writes update the cache before callbacks and resume queries.
            current_state.toggling = true
            local function finish(ok, ...)
                current_state.toggling = was_toggling
                if not ok then error((...), 0) end
                return ...
            end
            return finish(pcall(original_toggle, this, ...))
        end
        listener[TOGGLE_WRAPPER_STATE] = hook
        listener.onToggleFrontlight = hook.wrapper
    end
    state.listener = hook
    current_powerd[WRAPPER_STATE] = state
    for name, entry in pairs(state.methods) do
        current_powerd[name] = entry.wrapper
    end
    self.powerd = current_powerd
    self.wrapper_state = state
    return true
end

function KindleAutoBrightness:_restoreWrapper(powerd_to_restore)
    local current_powerd = powerd_to_restore or self.powerd or get_powerd(self.device or Device)
    if not current_powerd then
        return false
    end

    local state = current_powerd[WRAPPER_STATE]
    if not state then
        self.wrapper_state = nil
        return true
    end

    -- Other owners may retain our functions in their own wrapper chains.
    -- Deactivate the whole set before restoring the methods we still own.
    state.active = false
    for name, entry in pairs(state.methods) do
        if current_powerd[name] == entry.wrapper then
            current_powerd[name] = entry.original
        else
            logger.dbg("KindleAutoBrightness: leaving a changed frontlight method untouched", name)
        end
    end
    local hook = state.listener
    if get_powerd(Device) == current_powerd and rawget(hook.owner, TOGGLE_WRAPPER_STATE) == hook then
        hook.active = false
        if hook.owner.onToggleFrontlight == hook.wrapper then
            hook.owner.onToggleFrontlight = hook.original
        end
        hook.owner[TOGGLE_WRAPPER_STATE] = nil
    end
    current_powerd[WRAPPER_STATE] = nil
    self.wrapper_state = nil
    return true
end

function KindleAutoBrightness:_ensureWarmthWrapper()
    local current_powerd = get_powerd(self.device or Device)
    if not current_powerd or not has_warmth_reader(self.device or Device, current_powerd) then
        return false
    end

    local existing = current_powerd[WARMTH_WRAPPER_STATE]
    if existing and existing.wrapper and current_powerd.frontlightWarmth == existing.wrapper then
        self.warmth_powerd = current_powerd
        self.warmth_wrapper_state = existing
        return true
    end
    if existing then
        if current_powerd.frontlightWarmth == existing.original_method then
            current_powerd[WARMTH_WRAPPER_STATE] = nil
        else
            logger.dbg("KindleAutoBrightness: refusing to replace another frontlight warmth wrapper")
            return false
        end
    end

    local original_method = current_powerd.frontlightWarmth
    if type(original_method) ~= "function" then
        return false
    end

    local state = {
        original_method = original_method,
        original_raw_method = rawget(current_powerd, "frontlightWarmth"),
    }
    state.wrapper = make_warmth_wrapper(state)
    current_powerd[WARMTH_WRAPPER_STATE] = state
    current_powerd.frontlightWarmth = state.wrapper
    self.warmth_powerd = current_powerd
    self.warmth_wrapper_state = state
    return true
end

function KindleAutoBrightness:_restoreWarmthWrapper(powerd_to_restore)
    local current_powerd = powerd_to_restore or self.warmth_powerd or get_powerd(self.device or Device)
    if not current_powerd then
        return false
    end

    local state = current_powerd[WARMTH_WRAPPER_STATE]
    if not state then
        self.warmth_powerd = nil
        self.warmth_wrapper_state = nil
        return true
    end

    if current_powerd.frontlightWarmth ~= state.wrapper then
        logger.dbg("KindleAutoBrightness: leaving a changed frontlight warmth method untouched")
        return false
    end

    if state.original_raw_method == nil then
        current_powerd.frontlightWarmth = nil
    else
        current_powerd.frontlightWarmth = state.original_raw_method
    end
    current_powerd[WARMTH_WRAPPER_STATE] = nil
    self.warmth_powerd = nil
    self.warmth_wrapper_state = nil
    return true
end

function KindleAutoBrightness:_setEnabled(enabled)
    enabled = enabled == true
    if enabled then
        local installed = self:_ensureWrapper()
        self.enabled = installed
    else
        self:_restoreWrapper()
        self.enabled = false
    end
    G_reader_settings:saveSetting(SETTING, self.enabled)
    return self.enabled
end

function KindleAutoBrightness:_setWarmthEnabled(enabled)
    enabled = enabled == true
    if enabled then
        local current_powerd = get_powerd(self.device or Device)
        self.warmth_supported = has_warmth_reader(self.device or Device, current_powerd)
        if self.warmth_supported then
            self.warmth_enabled = self:_ensureWarmthWrapper()
        else
            self.warmth_enabled = false
        end
    else
        self:_restoreWarmthWrapper()
        self.warmth_enabled = false
    end
    G_reader_settings:saveSetting(WARMTH_SETTING, self.warmth_enabled)
    return self.warmth_enabled
end

function KindleAutoBrightness:init()
    self.device = Device
    self.warmth_supported = has_warmth_reader(self.device, get_powerd(self.device))
    local stored = G_reader_settings:readSetting(SETTING)
    if stored == nil then
        self.enabled = false
        G_reader_settings:saveSetting(SETTING, false)
    else
        self.enabled = G_reader_settings:isTrue(SETTING)
    end

    local stored_warmth = G_reader_settings:readSetting(WARMTH_SETTING)
    if self.warmth_supported and stored_warmth ~= nil then
        self.warmth_enabled = G_reader_settings:isTrue(WARMTH_SETTING)
    else
        self.warmth_enabled = false
        G_reader_settings:saveSetting(WARMTH_SETTING, false)
    end

    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end

    if self.enabled then
        if not self:_ensureWrapper() then
            self.enabled = false
            G_reader_settings:saveSetting(SETTING, false)
        end
    else
        self:_restoreWrapper()
    end

    if self.warmth_enabled then
        if not self:_ensureWarmthWrapper() then
            self.warmth_enabled = false
            G_reader_settings:saveSetting(WARMTH_SETTING, false)
        end
    else
        self:_restoreWarmthWrapper()
    end
end

function KindleAutoBrightness:onResume()
    if self.enabled and not self:_ensureWrapper() then
        self.enabled = false
        G_reader_settings:saveSetting(SETTING, false)
    end
    if self.warmth_enabled and not self:_ensureWarmthWrapper() then
        self.warmth_enabled = false
        G_reader_settings:saveSetting(WARMTH_SETTING, false)
    end
end

function KindleAutoBrightness:addToMainMenu(menu_items)
    menu_items.kindleautobrightness = {
        text = _("Synchronize with Kindle Auto Brightness"),
        sorting_hint = "more_tools",
        help_text = _([[
This external plugin requires native Kindle Auto Brightness to be enabled first.
It makes KOReader's brightness controls read Amazon's current hardware brightness; it does not
implement its own ambient light sensor (ALS) algorithm.]]),
        checked_func = function()
            return self.enabled
        end,
        check_callback_updates_menu = true,
        callback = function(touchmenu_instance)
            self:_setEnabled(not self.enabled)
            if touchmenu_instance then
                touchmenu_instance:updateItems()
            end
        end,
    }
    if self.warmth_supported then
        menu_items.kindleautobrightness_warmth = {
            text = _("Synchronize with Kindle scheduled warmth"),
            sorting_hint = "more_tools",
            help_text = _([[
This makes KOReader's warmth controls read the actual current Kindle hardware warmth on demand,
including changes made by Kindle's schedule. It does not choose or run a schedule.
If KOReader AutoWarmth is also enabled, the two schedulers remain independent; do not expect them
to cooperate as one algorithm.]]),
            checked_func = function()
                return self.warmth_enabled
            end,
            check_callback_updates_menu = true,
            callback = function(touchmenu_instance)
                self:_setWarmthEnabled(not self.warmth_enabled)
                if touchmenu_instance then
                    touchmenu_instance:updateItems()
                end
            end,
        }
    end
end

return KindleAutoBrightness
