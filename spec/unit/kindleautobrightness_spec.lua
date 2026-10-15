describe("Kindle Auto Brightness Bridge", function()
    local koreader_root = os.getenv("KINDLE_AUTO_BRIGHTNESS_KO")
    assert.is_truthy(koreader_root, "KINDLE_AUTO_BRIGHTNESS_KO must point to KOReader")

    local function extend(base, defaults)
        local class = defaults or {}
        class.__index = class
        setmetatable(class, { __index = base })
        function class:extend(values)
            local child = values or {}
            child.__index = child
            setmetatable(child, { __index = self })
            function child:new(attributes)
                local instance = attributes or {}
                setmetatable(instance, self)
                if instance.init then
                    instance:init()
                end
                return instance
            end
            return child
        end
        function class:new(attributes)
            local instance = attributes or {}
            setmetatable(instance, self)
            if instance.init then
                instance:init()
            end
            return instance
        end
        return class
    end

    package.preload["gettext"] = function()
        return setmetatable({
            pgettext = function(_, text) return text end,
        }, {
            __call = function(_, text) return text end,
        })
    end
    package.preload["logger"] = function()
        return {
            dbg = function() end,
            err = function() end,
        }
    end
    package.preload["ui/widget/container/widgetcontainer"] = function()
        return extend(nil)
    end
    package.preload["ui/widget/eventlistener"] = function()
        return extend(nil)
    end
    package.preload["ui/event"] = function()
        return {
            new = function(_, name, arg)
                return { name = name, arg = arg }
            end,
        }
    end
    package.preload["ffi/util"] = function()
        return {
            template = function(text, value)
                return (text:gsub("%%1", tostring(value)))
            end,
        }
    end
    package.preload["device/devicelistener"] = function()
        local chunk = assert(loadfile(koreader_root .. "/frontend/device/devicelistener.lua"))
        return chunk()
    end

    _G.G_reader_settings = {
        values = {},
        reset = function(self, values) self.values = values or {} end,
        readSetting = function(self, key, default)
            local value = self.values[key]
            if value == nil then return default end
            return value
        end,
        saveSetting = function(self, key, value) self.values[key] = value end,
        isTrue = function(self, key) return self.values[key] == true end,
    }

    package.replace = function(name, module)
        package.loaded[name] = module
    end
    package.unload = function(name)
        package.loaded[name] = nil
    end

    local repo_root = os.getenv("KINDLE_AUTO_BRIGHTNESS_ROOT")
    assert.is_truthy(repo_root, "KINDLE_AUTO_BRIGHTNESS_ROOT must point to the plugin repository")
    local main_path = repo_root .. "/kindleautobrightness.koplugin/main.lua"

    local original_device
    local original_notification
    local original_uimanager
    local original_devicelistener

    local SETTING = "kindleautobrightness_enabled"
    local WARMTH_SETTING = "kindleautobrightness_warmth_enabled"
    local WRAPPER_STATE = "_kindle_auto_brightness_bridge_state"
    local WARMTH_WRAPPER_STATE = "_kindle_auto_warmth_bridge_state"

    local function reset_settings()
        _G.G_reader_settings:reset({})
    end

    local function make_powerd(options)
        options = options or {}
        local warmth_max = options.fl_warmth_max or 24
        local powerd = {
            fl_min = options.fl_min or 0,
            fl_max = options.fl_max or 24,
            fl_intensity = options.fl_intensity or 10,
            hardware = options.hardware or 20,
            is_fl_on = options.is_fl_on ~= false,
            fl_warmth_min = options.fl_warmth_min or 0,
            fl_warmth_max = warmth_max,
            fl_warmth = options.fl_warmth or 50,
            hardware_warmth = options.hardware_warmth or 12,
            warmth_scale = 100 / warmth_max,
            warmth_writes = 0,
            warmth_reads = 0,
        }

        powerd.frontlightIntensityHW = options.frontlightIntensityHW or function(self)
            return self.hardware
        end
        powerd.toNativeWarmth = function(self, warmth)
            return math.floor(warmth / self.warmth_scale + 0.5)
        end
        powerd.fromNativeWarmth = function(self, warmth)
            return math.floor(warmth * self.warmth_scale + 0.5)
        end
        powerd.frontlightWarmthHW = options.frontlightWarmthHW or function(self)
            self.warmth_reads = self.warmth_reads + 1
            return self:fromNativeWarmth(self.hardware_warmth)
        end
        powerd.setWarmthHW = function(self, warmth)
            self.warmth_writes = self.warmth_writes + 1
            self.hardware_warmth = warmth
        end
        powerd.frontlightWarmth = function(self)
            return self.fl_warmth
        end
        powerd.setWarmth = function(self, warmth)
            if warmth == self:frontlightWarmth() then
                return false
            end
            self.fl_warmth = math.min(100, math.max(0, warmth))
            self:setWarmthHW(self:toNativeWarmth(self.fl_warmth))
            return true
        end

        if options.als_lux ~= nil then
            powerd.lipc_handle = {
                get_int_property = function(_, service, property)
                    assert.equals("com.lab126.powerd", service)
                    assert.equals("alsLux", property)
                    if options.als_lux == "error" then
                        error("ALS read failed")
                    end
                    return options.als_lux
                end,
            }
        end

        powerd.frontlightIntensity = function(self)
            if not self.is_fl_on then
                return 0
            end
            return self.fl_intensity
        end

        powerd.isFrontlightOff = function(self)
            return self.hardware <= self.fl_min
        end

        powerd.stateChanged = function() end
        powerd.updateResumeFrontlightState = function(self)
            self.resume_was_on = self.is_fl_on
        end

        powerd.setIntensityHW = function(self, intensity)
            self.hardware = intensity
            if intensity > self.fl_min then
                self.fl_intensity = intensity
                self.is_fl_on = true
            else
                self.is_fl_on = false
            end
        end

        powerd.setIntensity = function(self, intensity)
            if intensity == self:frontlightIntensity() then
                return false
            end
            if intensity < self.fl_min then
                intensity = self.fl_min
            elseif intensity > self.fl_max then
                intensity = self.fl_max
            end
            self:setIntensityHW(intensity)
            return true
        end

        powerd.turnOffFrontlight = function(self)
            if self.hardware <= self.fl_min then
                return false
            end
            self:setIntensityHW(self.fl_min)
            return true
        end

        powerd.turnOnFrontlight = function(self)
            if self.hardware > self.fl_min then
                return false
            end
            self:setIntensityHW(self.fl_intensity > self.fl_min and self.fl_intensity or self.fl_min + 1)
            return true
        end

        if options.remove_live_reader then
            powerd.frontlightIntensityHW = nil
        end
        if options.remove_warmth_reader then
            powerd.frontlightWarmthHW = nil
        end
        return powerd
    end

    local function make_device(options)
        options = options or {}
        local powerd = options.powerd or make_powerd(options)
        local device = {
            powerd = powerd,
            screen = {
                getWidth = function() return 100 end,
                getHeight = function() return 200 end,
            },
            show_light_dialog_calls = 0,
        }
        function device:isKindle()
            return options.kindle ~= false
        end
        function device:hasFrontlight()
            return options.frontlight ~= false
        end
        function device:hasLightSensor()
            return options.light_sensor ~= false
        end
        function device:hasNaturalLight()
            return options.natural_light ~= false
        end
        function device:hasGSensor()
            return false
        end
        function device:isAlwaysFullscreen()
            return true
        end
        function device:getPowerDevice()
            return self.powerd
        end
        function device:showLightDialog()
            self.show_light_dialog_calls = self.show_light_dialog_calls + 1
            self.dialog_intensity = self.powerd:frontlightIntensity()
        end
        return device
    end

    local function load_plugin(device)
        original_device = package.loaded.device
        package.replace("device", device)
        return dofile(main_path)
    end

    local function new_plugin(options, setting, warmth_setting)
        reset_settings()
        local device = make_device(options)
        if setting ~= nil then
            _G.G_reader_settings:saveSetting(SETTING, setting)
        end
        if warmth_setting ~= nil then
            _G.G_reader_settings:saveSetting(WARMTH_SETTING, warmth_setting)
        end
        local menu = {}
        function menu:registerToMainMenu(plugin)
            self.plugin = plugin
        end
        local plugin_class = load_plugin(device)
        if plugin_class.disabled then
            return plugin_class, nil, menu, device, device.powerd
        end
        local plugin = plugin_class:new{ ui = { menu = menu } }
        return plugin_class, plugin, menu, device, device.powerd
    end

    local function restore_module(name, module)
        package.replace(name, module)
    end

    local function load_device_listener(device, notifications)
        original_notification = package.loaded["ui/widget/notification"]
        original_uimanager = package.loaded["ui/uimanager"]
        original_devicelistener = package.loaded["device/devicelistener"]
        package.replace("device", device)
        package.replace("ui/widget/notification", {
            notify = function(_, text)
                table.insert(notifications, text)
            end,
        })
        package.replace("ui/uimanager", {
            broadcastEvent = function() end,
        })
        package.unload("device/devicelistener")
        return require("device/devicelistener")
    end

    -- Run the real generic/Kindle controllers; only the platform boundary is simulated.
    local function new_kindle_plugin()
        package.preload["optmath"] = function()
            return { round = function(n) return math.floor(n + 0.5) end }
        end
        package.preload["ui/time"] = function() return { s = function(n) return n end } end
        package.preload["device/wakeupmgr"] = function() return {} end
        package.preload["device/generic/powerd"] = function()
            return assert(loadfile(koreader_root .. "/frontend/device/generic/powerd.lua"))()
        end
        local device = make_device({ natural_light = false })
        function device:canTurnFrontlightOff() return true end
        local hardware = { intensity = 10, writes = 0 }
        local KindlePowerD = assert(loadfile(koreader_root .. "/frontend/device/kindle/powerd.lua"))()
        local powerd = KindlePowerD:new{
            device = device,
            init = function() end,
            lipc_handle = {
                get_int_property = function(_, _, property)
                    assert.equals("flIntensity", property)
                    return hardware.intensity
                end,
                set_int_property = function(_, _, property, value)
                    assert.equals("flIntensity", property)
                    hardware.intensity = value
                    hardware.writes = hardware.writes + 1
                end,
            },
        }
        device.powerd = powerd
        local notifications = {}
        local listener_class = load_device_listener(device, notifications)
        local _, plugin = new_plugin({ powerd = powerd, natural_light = false }, true)
        local listener = listener_class:new{}
        return plugin, powerd, hardware, listener, notifications, device
    end

    before_each(function()
        original_device = package.loaded.device
        original_notification = package.loaded["ui/widget/notification"]
        original_uimanager = package.loaded["ui/uimanager"]
        original_devicelistener = package.loaded["device/devicelistener"]
    end)

    after_each(function()
        restore_module("device", original_device)
        restore_module("ui/widget/notification", original_notification)
        restore_module("ui/uimanager", original_uimanager)
        restore_module("device/devicelistener", original_devicelistener)
        reset_settings()
    end)

    it("toggles external re-enabling off immediately through the real Kindle notification path", function()
        local _, powerd, hardware, listener, notifications = new_kindle_plugin()
        listener:onToggleFrontlight()
        assert.equals(0, hardware.intensity)
        assert.equals("Frontlight disabled.", notifications[#notifications])
        hardware.intensity = 20
        listener:onToggleFrontlight()
        assert.equals(0, hardware.intensity)
        assert.equals("Frontlight disabled.", notifications[#notifications])
        assert.equals(20, powerd.fl_intensity)
    end)

    it("observes external changes without writes and restores the last nonzero Kindle brightness", function()
        local _, powerd, hardware, listener, notifications = new_kindle_plugin()
        hardware.intensity = 18
        assert.is_true(powerd:isFrontlightOn())
        assert.is_false(powerd:isFrontlightOff())
        assert.equals(18, powerd:frontlightIntensity())
        hardware.intensity = 0
        assert.is_false(powerd:isFrontlightOn())
        assert.is_true(powerd:isFrontlightOff())
        assert.equals(0, powerd:frontlightIntensity())
        assert.equals(18, powerd.fl_intensity)
        assert.equals(0, hardware.writes)
        listener:onToggleFrontlight()
        assert.equals(18, hardware.intensity)
        assert.equals("Frontlight enabled.", notifications[#notifications])
        assert.is_true(powerd.fl_was_on)
    end)

    it("keeps real Kindle observations and toggles usable when live reads fail", function()
        local readers = {
            function() return nil end,
            function() error("temporary read failure") end,
            function() return "20" end,
            function() return 0 / 0 end,
            function() return -1 end,
            function() return 25 end,
        }
        for _, reader in ipairs(readers) do
            local _, powerd, hardware, listener, notifications = new_kindle_plugin()
            powerd.frontlightIntensityHW = reader
            assert.is_true(powerd:isFrontlightOn())
            assert.is_false(powerd:isFrontlightOff())
            assert.equals(10, powerd:frontlightIntensity())
            assert.equals(0, hardware.writes)
            listener:onToggleFrontlight()
            assert.equals(0, hardware.intensity)
            assert.equals("Frontlight disabled.", notifications[#notifications])
            assert.is_false(powerd:isFrontlightOn())
            assert.is_true(powerd:isFrontlightOff())
            listener:onToggleFrontlight()
            assert.equals(10, hardware.intensity)
            assert.equals("Frontlight enabled.", notifications[#notifications])
            assert.is_true(powerd:isFrontlightOn())
        end
    end)

    it("uses one live sample per real public query despite nested original state queries", function()
        local _, powerd, hardware = new_kindle_plugin()
        local reads = 0
        powerd.frontlightIntensityHW = function()
            reads = reads + 1
            assert.is_true(reads <= 1, "nested observation or recursion")
            return hardware.intensity
        end
        for _, name in ipairs({ "frontlightIntensity", "isFrontlightOn", "isFrontlightOff" }) do
            reads = 0
            powerd[name](powerd)
            assert.equals(1, reads)
        end
        assert.equals(0, hardware.writes)
    end)

    it("restores inherited Kindle methods and preserves another owner's state replacement", function()
        local plugin, powerd, hardware = new_kindle_plugin()
        local names = { "frontlightIntensity", "isFrontlightOn", "isFrontlightOff", "isFrontlightOnHW" }
        local wrappers = {}
        for _, name in ipairs(names) do wrappers[name] = powerd[name] end
        plugin:_setEnabled(true)
        plugin:onResume()
        plugin:onResume()
        for _, name in ipairs(names) do assert.equals(wrappers[name], powerd[name]) end
        local replacement = function() return "other owner" end
        powerd.isFrontlightOff = replacement
        plugin:onResume()
        assert.equals(replacement, powerd.isFrontlightOff)
        plugin:_setEnabled(false)
        assert.equals(replacement, powerd.isFrontlightOff)
        for _, name in ipairs({ "frontlightIntensity", "isFrontlightOn", "isFrontlightOnHW" }) do
            assert.is_nil(rawget(powerd, name))
            assert.are_not.equal(wrappers[name], powerd[name])
        end
        assert.is_nil(powerd[WRAPPER_STATE])
        hardware.intensity = 0
        assert.is_true(powerd:isFrontlightOn()) -- disabled: original cached behavior
        assert.equals(0, hardware.writes)
        plugin:_setEnabled(false)
        assert.equals(replacement, powerd.isFrontlightOff)
    end)

    it("stops all brightness synchronization when resume encounters another owner's replacement", function()
        local plugin, powerd, hardware = new_kindle_plugin()
        powerd.isFrontlightOff = function() return false end
        plugin:onResume()
        assert.is_false(plugin.enabled)
        assert.is_false(G_reader_settings:isTrue(SETTING))
        hardware.intensity = 0
        assert.is_true(powerd:isFrontlightOn())
        assert.equals(10, powerd:frontlightIntensity())
        assert.equals(10, powerd.fl_intensity)
        assert.is_nil(powerd[WRAPPER_STATE])
    end)

    it("deactivates captured bridge wrappers while preserving another owner's wrapper", function()
        local plugin, powerd, hardware = new_kindle_plugin()
        local captured = powerd.isFrontlightOn
        local replacement = function(this) return captured(this) end
        powerd.isFrontlightOn = replacement
        plugin:_setEnabled(false)
        hardware.intensity = 0
        assert.equals(replacement, powerd.isFrontlightOn)
        assert.is_true(powerd:isFrontlightOn())
        assert.equals(10, powerd:frontlightIntensity())
        assert.equals(10, powerd.fl_intensity)
        plugin:_setEnabled(true)
        assert.is_true(plugin.enabled)
        assert.is_false(powerd:isFrontlightOn())
        plugin:_setEnabled(false)
        assert.equals(replacement, powerd.isFrontlightOn)
        hardware.intensity = 20
        assert.is_false(powerd:isFrontlightOn())
    end)

    it("uses the first observation for both the toggle action and its notification", function()
        local _, powerd, hardware, listener, notifications = new_kindle_plugin()
        local reads = 0
        powerd.frontlightIntensityHW = function()
            reads = reads + 1
            if reads == 2 then hardware.intensity = 0 end
            return hardware.intensity
        end
        listener:onToggleFrontlight()
        assert.equals(0, hardware.intensity)
        assert.equals("Frontlight disabled.", notifications[#notifications])
        assert.is_false(powerd.fl_was_on)
    end)

    it("keeps an invalid entry observation coherent and clears the scope after handler errors", function()
        local _, powerd, hardware, listener, notifications = new_kindle_plugin()
        local reads = 0
        powerd.frontlightIntensityHW = function()
            reads = reads + 1
            if reads == 1 then return nil end
            return 0
        end
        listener:onToggleFrontlight()
        assert.equals(0, hardware.intensity)
        assert.equals("Frontlight disabled.", notifications[#notifications])
        powerd.frontlightIntensityHW = function() return hardware.intensity end
        hardware.intensity = 10
        powerd.lipc_handle.set_int_property = function() error("write failed") end
        assert.has_error(function() listener:onToggleFrontlight() end, "write failed")
        hardware.intensity = 0
        assert.is_false(powerd:isFrontlightOn())
    end)

    it("restores nested toggle scopes and deactivates another owner's captured handler", function()
        local plugin, powerd, hardware, listener, notifications = new_kindle_plugin()
        local notification = require("ui/widget/notification")
        local notify = notification.notify
        local nested = false
        notification.notify = function(this, text)
            notify(this, text)
            if not nested then
                nested = true
                listener:onToggleFrontlight()
            end
        end
        listener:onToggleFrontlight()
        assert.equals(10, hardware.intensity)
        assert.equals("Frontlight enabled.", notifications[#notifications])
        hardware.intensity = 0
        assert.is_false(powerd:isFrontlightOn())
        local listener_class = require("device/devicelistener")
        local captured = listener_class.onToggleFrontlight
        local replacement = function(this, ...) return captured(this, ...) end
        listener_class.onToggleFrontlight = replacement
        plugin:_setEnabled(false)
        assert.equals(replacement, listener_class.onToggleFrontlight)
        hardware.intensity = 20
        listener:onToggleFrontlight()
        assert.equals(10, hardware.intensity) -- disabled: original cached-off decision
        assert.equals("Frontlight enabled.", notifications[#notifications])
    end)

    it("reuses the handler hook and observes the current power device across plugin instances", function()
        local _, powerd, hardware, listener, notifications, device = new_kindle_plugin()
        local listener_class = require("device/devicelistener")
        local hook = listener_class.onToggleFrontlight
        local next_powerd = getmetatable(powerd):new{
            device = device,
            init = function() end,
            lipc_handle = powerd.lipc_handle,
        }
        device.powerd = next_powerd
        local next_plugin = load_plugin(device):new{}
        assert.equals(hook, listener_class.onToggleFrontlight)
        hardware.intensity = 20
        listener:onToggleFrontlight()
        assert.equals(0, hardware.intensity)
        assert.equals("Frontlight disabled.", notifications[#notifications])
        assert.equals(20, next_powerd.fl_intensity)
        next_plugin:_setEnabled(false)
        assert.are_not.equal(hook, listener_class.onToggleFrontlight)
    end)

    it("preserves another handler owner's arguments and multiple return values", function()
        local plugin, _, _, listener = new_kindle_plugin()
        plugin:_setEnabled(false)
        local listener_class = require("device/devicelistener")
        local original = listener_class.onToggleFrontlight
        listener_class.onToggleFrontlight = function(this, first, second)
            original(this)
            return first, nil, second
        end
        plugin:_setEnabled(true)
        local function collect(...) return { n = select("#", ...), ... } end
        local results = collect(listener:onToggleFrontlight("first", "second"))
        assert.same({ n = 3, [1] = "first", [3] = "second" }, results)
    end)

    it("is disabled on non-Kindle, non-ALS, non-frontlit, and API-unsupported devices", function()
        local cases = {
            { kindle = false },
            { light_sensor = false },
            { frontlight = false },
            { remove_live_reader = true },
        }
        for _, options in ipairs(cases) do
            local plugin_class = new_plugin(options)
            assert.is_true(plugin_class.disabled)
        end
    end)

    it("detects a native Kindle ALS when KOReader's model flag is incomplete", function()
        local plugin_class, plugin = new_plugin({
            light_sensor = false,
            als_lux = 40,
        })
        assert.is_nil(plugin_class.disabled)
        assert.is_not_nil(plugin)
    end)

    it("loads when the live API exists even if its startup read would fail", function()
        local readers = {
            function() return nil end,
            function() error("startup read failed") end,
            function() return 25 end,
        }
        for _, reader in ipairs(readers) do
            local plugin_class, plugin, _, _, powerd = new_plugin({
                frontlightIntensityHW = reader,
            })
            assert.is_nil(plugin_class.disabled)
            assert.is_not_nil(plugin)
            assert.equals(10, powerd:frontlightIntensity())
        end
    end)

    it("starts disabled and persists an explicit false default", function()
        local plugin_class, plugin, _, _, powerd = new_plugin({})
        assert.is_nil(plugin_class.disabled)
        assert.is_false(plugin.enabled)
        assert.is_false(_G.G_reader_settings:readSetting(SETTING))
        assert.is_nil(powerd[WRAPPER_STATE])
    end)

    it("provides translated long-press help for the brightness setting", function()
        local _, plugin = new_plugin({})
        local menu_items = {}
        plugin:addToMainMenu(menu_items)

        local help_text = menu_items.kindleautobrightness.help_text
        assert.is_string(help_text)
        assert.is_truthy(help_text:find("external plugin", 1, true))
        assert.is_truthy(help_text:find("Amazon", 1, true))
        assert.is_truthy(help_text:find("hardware brightness", 1, true))
        assert.is_truthy(help_text:find("native Kindle Auto Brightness", 1, true))
        assert.is_truthy(help_text:find("does not", 1, true))
        assert.is_truthy(help_text:find("ambient light sensor", 1, true))
        assert.is_truthy(help_text:find("algorithm", 1, true))
    end)

    it("starts warmth synchronization disabled and persists an explicit false default", function()
        local _, plugin, _, _, powerd = new_plugin({})
        assert.is_false(plugin.warmth_enabled)
        assert.is_false(_G.G_reader_settings:readSetting(WARMTH_SETTING))
        assert.is_nil(powerd[WARMTH_WRAPPER_STATE])

        local menu_items = {}
        plugin:addToMainMenu(menu_items)
        local item = menu_items.kindleautobrightness_warmth
        assert.is_not_nil(item)
        assert.is_false(item.checked_func())
    end)

    it("toggles warmth synchronization persistently and immediately", function()
        local _, plugin, _, _, powerd = new_plugin({})
        local menu_items = {}
        plugin:addToMainMenu(menu_items)
        local item = menu_items.kindleautobrightness_warmth

        item.callback()
        assert.is_true(plugin.warmth_enabled)
        assert.is_true(_G.G_reader_settings:isTrue(WARMTH_SETTING))
        assert.is_not_nil(powerd[WARMTH_WRAPPER_STATE])
        assert.is_true(item.checked_func())

        item.callback()
        assert.is_false(plugin.warmth_enabled)
        assert.is_false(_G.G_reader_settings:isTrue(WARMTH_SETTING))
        assert.is_nil(powerd[WARMTH_WRAPPER_STATE])
        assert.is_false(item.checked_func())
    end)

    it("restores persisted warmth synchronization on startup", function()
        local _, plugin, _, _, powerd = new_plugin({}, nil, true)
        assert.is_true(plugin.warmth_enabled)
        assert.is_true(_G.G_reader_settings:isTrue(WARMTH_SETTING))
        assert.is_not_nil(powerd[WARMTH_WRAPPER_STATE])
    end)

    it("hides warmth synchronization without natural light or a hardware reader", function()
        local cases = {
            { natural_light = false },
            { remove_warmth_reader = true },
        }
        for _, options in ipairs(cases) do
            local _, plugin = new_plugin(options, nil, true)
            assert.is_false(plugin.warmth_enabled)
            assert.is_false(_G.G_reader_settings:isTrue(WARMTH_SETTING))

            local menu_items = {}
            plugin:addToMainMenu(menu_items)
            assert.is_nil(menu_items.kindleautobrightness_warmth)
        end
    end)

    it("reads live warmth in the KOReader scale without writing hardware", function()
        local _, plugin, _, _, powerd = new_plugin({
            hardware_warmth = 6,
        })
        plugin:_setWarmthEnabled(true)
        powerd.fl_warmth = 75

        assert.equals(25, powerd:frontlightWarmth())
        assert.equals(25, powerd.fl_warmth)
        assert.equals(0, powerd.warmth_writes)
        assert.equals(1, powerd.warmth_reads)
    end)

    it("uses live warmth through DeviceListener increase and decrease gestures", function()
        local _, plugin, _, device, powerd = new_plugin({
            hardware_warmth = 6,
        })
        plugin:_setWarmthEnabled(true)
        local notifications = {}
        local device_listener = load_device_listener(device, notifications)
        local listener = setmetatable({}, { __index = device_listener })

        powerd.fl_warmth = 75
        listener:onIncreaseFlWarmth(1)
        assert.equals(7, powerd.hardware_warmth)
        assert.equals(29, powerd.fl_warmth)
        assert.equals("Warmth set to 7.", notifications[#notifications])

        powerd.hardware_warmth = 10
        powerd.fl_warmth = 75
        listener:onDecreaseFlWarmth(1)
        assert.equals(9, powerd.hardware_warmth)
        assert.equals(38, powerd.fl_warmth)
        assert.equals("Warmth set to 9.", notifications[#notifications])
    end)

    it("preserves cached warmth for invalid live reads and keeps manual warmth usable", function()
        local _, plugin, _, _, powerd = new_plugin({})
        plugin:_setWarmthEnabled(true)
        local invalid_readers = {
            function() return nil end,
            function() error("temporary warmth read failure") end,
            function() return "50" end,
            function() return 101 end,
            function() return -1 end,
            function() return 0 / 0 end,
        }
        for _, reader in ipairs(invalid_readers) do
            powerd.frontlightWarmthHW = reader
            powerd.fl_warmth = 42
            powerd.hardware_warmth = 12
            local ok, result = pcall(function() return powerd:frontlightWarmth() end)
            assert.is_true(ok)
            assert.equals(42, result)
            assert.equals(42, powerd.fl_warmth)

            assert.is_true(powerd:setWarmth(50))
            assert.equals(50, powerd.fl_warmth)
            assert.equals(12, powerd.hardware_warmth)
        end
    end)

    it("keeps brightness and warmth wrappers independently idempotent and reversible", function()
        local _, plugin, _, _, powerd = new_plugin({})
        local original_intensity = powerd.frontlightIntensity
        local original_warmth = powerd.frontlightWarmth

        plugin:_setEnabled(true)
        local intensity_wrapper = powerd.frontlightIntensity
        plugin:_setWarmthEnabled(true)
        local warmth_wrapper = powerd.frontlightWarmth
        assert.are_not.equal(intensity_wrapper, warmth_wrapper)
        assert.is_not_nil(powerd[WRAPPER_STATE])
        assert.is_not_nil(powerd[WARMTH_WRAPPER_STATE])

        plugin:_setEnabled(true)
        plugin:_setWarmthEnabled(true)
        plugin:onResume()
        plugin:onResume()
        assert.equals(intensity_wrapper, powerd.frontlightIntensity)
        assert.equals(warmth_wrapper, powerd.frontlightWarmth)

        plugin:_setWarmthEnabled(false)
        assert.equals(original_warmth, powerd.frontlightWarmth)
        assert.equals(original_warmth, rawget(powerd, "frontlightWarmth"))
        assert.is_nil(powerd[WARMTH_WRAPPER_STATE])
        assert.equals(intensity_wrapper, powerd.frontlightIntensity)

        plugin:_setEnabled(false)
        assert.equals(original_intensity, powerd.frontlightIntensity)
        assert.equals(original_intensity, rawget(powerd, "frontlightIntensity"))
        assert.is_nil(powerd[WRAPPER_STATE])
        assert.is_nil(plugin.timer)
        assert.is_nil(plugin.timers)
    end)

    it("toggles persistently and installs the live wrapper immediately", function()
        local _, plugin, menu, _, powerd = new_plugin({})
        local menu_items = {}
        plugin:addToMainMenu(menu_items)
        local item = menu_items.kindleautobrightness
        assert.equals("more_tools", item.sorting_hint)
        assert.is_false(item.checked_func())

        local updates = 0
        item.callback({ updateItems = function() updates = updates + 1 end })
        assert.is_true(plugin.enabled)
        assert.is_true(_G.G_reader_settings:isTrue(SETTING))
        assert.is_not_nil(powerd[WRAPPER_STATE])
        assert.equals(1, updates)
        assert.is_true(item.checked_func())

        item.callback({ updateItems = function() updates = updates + 1 end })
        assert.is_false(plugin.enabled)
        assert.is_false(_G.G_reader_settings:isTrue(SETTING))
        assert.is_nil(powerd[WRAPPER_STATE])
        assert.equals(2, updates)
    end)

    it("is idempotent, restores the exact raw method, and survives resume", function()
        local _, plugin, _, _, powerd = new_plugin({}, true)
        local original_method = powerd[WRAPPER_STATE].original_raw_method
        assert.is_not_nil(powerd[WRAPPER_STATE])

        local wrapped_method = powerd.frontlightIntensity
        plugin:_setEnabled(true)
        plugin:onResume()
        plugin:onResume()
        assert.equals(wrapped_method, powerd.frontlightIntensity)

        plugin:_setEnabled(false)
        assert.equals(original_method, powerd.frontlightIntensity)
        assert.equals(original_method, rawget(powerd, "frontlightIntensity"))
        assert.is_nil(powerd[WRAPPER_STATE])

        plugin:_setEnabled(false)
        assert.equals(original_method, powerd.frontlightIntensity)
    end)

    it("uses live hardware through DeviceListener increments and reports the result", function()
        local _, plugin, _, device, powerd = new_plugin({}, true)
        local notifications = {}
        local device_listener = load_device_listener(device, notifications)
        local listener = setmetatable({}, { __index = device_listener })

        powerd.fl_intensity = 10
        powerd.hardware = 20
        powerd.is_fl_on = true
        listener:onChangeFlIntensity(1, 1)
        assert.equals(21, powerd.hardware)
        assert.equals(21, powerd.fl_intensity)
        assert.equals("Frontlight intensity set to 21.", notifications[#notifications])

        powerd.fl_intensity = 10
        powerd.hardware = 20
        powerd.is_fl_on = true
        listener:onChangeFlIntensity(1, -1)
        assert.equals(19, powerd.hardware)
        assert.equals(19, powerd.fl_intensity)
    end)

    it("keeps absolute brightness setting authoritative", function()
        local _, plugin, _, device, powerd = new_plugin({}, true)
        local device_listener = load_device_listener(device, {})
        local listener = setmetatable({}, { __index = device_listener })

        listener:onSetFlIntensity(12)
        assert.equals(12, powerd.hardware)
        assert.equals(12, powerd.fl_intensity)
    end)

    it("falls back without changing the cache for nil, errors, strings, and out-of-range reads", function()
        local _, plugin, _, _, powerd = new_plugin({}, true)
        local invalid_readers = {
            function() return nil end,
            function() error("temporary read failure") end,
            function() return "20" end,
            function() return 25 end,
            function() return -1 end,
        }
        for _, reader in ipairs(invalid_readers) do
            powerd.frontlightIntensityHW = reader
            powerd.fl_intensity = 10
            powerd.is_fl_on = true
            powerd.hardware = 20
            local ok, result = pcall(function() return powerd:frontlightIntensity() end)
            assert.is_true(ok)
            assert.equals(10, result)
            assert.equals(10, powerd.fl_intensity)
            assert.is_true(powerd:setIntensity(12))
            assert.equals(12, powerd.hardware)
            powerd.hardware = 20
        end
    end)

    it("does not erase remembered brightness when hardware is at the minimum", function()
        local _, plugin, _, _, powerd = new_plugin({}, true)
        powerd.fl_intensity = 10
        powerd.hardware = powerd.fl_min
        powerd.is_fl_on = true

        assert.equals(0, powerd:frontlightIntensity())
        assert.equals(10, powerd.fl_intensity)
        assert.is_false(powerd.is_fl_on)

        powerd:turnOnFrontlight()
        assert.equals(10, powerd.hardware)
        assert.equals(10, powerd.fl_intensity)
    end)

    it("lets the existing frontlight-dialog path obtain the live value", function()
        local _, plugin, _, device, powerd = new_plugin({}, true)
        powerd.hardware = 20
        powerd.fl_intensity = 10
        local notifications = {}
        local device_listener = load_device_listener(device, notifications)
        local listener = setmetatable({}, { __index = device_listener })

        listener:onShowFlDialog()
        assert.equals(1, device.show_light_dialog_calls)
        assert.equals(20, device.dialog_intensity)
    end)

    it("does not add timers or duplicate wrappers across suspend/resume", function()
        local _, plugin, _, _, powerd = new_plugin({}, true)
        local wrapper = powerd.frontlightIntensity
        plugin:onResume()
        plugin:onResume()
        assert.equals(wrapper, powerd.frontlightIntensity)
        assert.is_nil(plugin.timer)
        assert.is_nil(plugin.timers)
    end)
end)
