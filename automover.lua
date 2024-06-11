obs = obslua
local ffi = require("ffi")
local log_file_path = "mouse_tracking_log.txt"

-- Declare global variables
source_name = ""
screen_width = 2560
screen_height = 1440
canvas_height = 2160
canvas_width = 3840 -- This will be calculated
center_position_x = -700
far_left_position_x = 0
far_right_position_x = -1400
hotkey_id = obs.OBS_INVALID_HOTKEY_ID
script_active = false

local win_point = nil
local x11_display = nil
local x11_root = nil
local x11_mouse = nil
local osx_lib = nil
local osx_nsevent = nil
local osx_mouse_location = nil

-- Define the mouse cursor functions for each platform
if ffi.os == "Windows" then
    ffi.cdef([[
        typedef int BOOL;
        typedef struct {
            long x;
            long y;
        } POINT, *LPPOINT;
        BOOL GetCursorPos(LPPOINT);
    ]])
    win_point = ffi.new("POINT[1]")
elseif ffi.os == "Linux" then
    ffi.cdef([[
        typedef unsigned long XID;
        typedef XID Window;
        typedef void Display;
        Display* XOpenDisplay(char*);
        XID XDefaultRootWindow(Display *display);
        int XQueryPointer(Display*, Window, Window*, Window*, int*, int*, int*, int*, unsigned int*);
        int XCloseDisplay(Display*);
    ]])

    x11_lib = ffi.load("X11.so.6")
    x11_display = x11_lib.XOpenDisplay(nil)
    if x11_display ~= nil then
        x11_root = x11_lib.XDefaultRootWindow(x11_display)
        x11_mouse = {
            root_win = ffi.new("Window[1]"),
            child_win = ffi.new("Window[1]"),
            root_x = ffi.new("int[1]"),
            root_y = ffi.new("int[1]"),
            win_x = ffi.new("int[1]"),
            win_y = ffi.new("int[1]"),
            mask = ffi.new("unsigned int[1]")
        }
    end
elseif ffi.os == "OSX" then
    ffi.cdef([[
        typedef struct {
            double x;
            double y;
        } CGPoint;
        typedef void* SEL;
        typedef void* id;
        typedef void* Method;

        SEL sel_registerName(const char *str);
        id objc_getClass(const char*);
        Method class_getClassMethod(id cls, SEL name);
        void* method_getImplementation(Method);
        int access(const char *path, int amode);
    ]])

    osx_lib = ffi.load("libobjc")
    if osx_lib ~= nil then
        osx_nsevent = {
            class = osx_lib.objc_getClass("NSEvent"),
            sel = osx_lib.sel_registerName("mouseLocation")
        }
        local method = osx_lib.class_getClassMethod(osx_nsevent.class, osx_nsevent.sel)
        if method ~= nil then
            local imp = osx_lib.method_getImplementation(method)
            osx_mouse_location = ffi.cast("CGPoint(*)(void*, void*)", imp)
        end
    end
end

-- Calculate canvas width
function calculate_canvas_width()
    canvas_width = (canvas_height / screen_height) * screen_width
    print("Calculated canvas width: " .. canvas_width)
end

-- Script properties
function script_properties()
    local props = obs.obs_properties_create()

    -- Add a dropdown list for source selection
    local p = obs.obs_properties_add_list(props, "source_name", "Source Name",
        obs.OBS_COMBO_TYPE_EDITABLE, obs.OBS_COMBO_FORMAT_STRING)
    
    local sources = obs.obs_enum_sources()
    if sources then
        for _, source in ipairs(sources) do
            local source_id = obs.obs_source_get_unversioned_id(source)
            if source_id == "monitor_capture" or source_id == "window_capture" or source_id == "game_capture" or source_id == "display_capture" then
                obs.obs_property_list_add_string(p, obs.obs_source_get_name(source), obs.obs_source_get_name(source))
            end
        end
    end
    obs.source_list_release(sources)

    obs.obs_properties_add_int(props, "screen_width", "Screen Width", 100, 10000, 1)
    obs.obs_properties_add_int(props, "screen_height", "Screen Height", 100, 10000, 1)
    obs.obs_properties_add_int(props, "canvas_height", "Canvas Height", 100, 10000, 1)
    obs.obs_properties_add_int(props, "center_position_x", "Center Position X", -10000, 10000, 1)
    obs.obs_properties_add_int(props, "far_left_position_x", "Far Left Position X", -10000, 10000, 1)
    obs.obs_properties_add_int(props, "far_right_position_x", "Far Right Position X", -10000, 10000, 1)
    return props
end

-- Script update function
function script_update(settings)
    source_name = obs.obs_data_get_string(settings, "source_name")
    screen_width = obs.obs_data_get_int(settings, "screen_width")
    screen_height = obs.obs_data_get_int(settings, "screen_height")
    canvas_height = obs.obs_data_get_int(settings, "canvas_height")
    center_position_x = obs.obs_data_get_int(settings, "center_position_x")
    far_left_position_x = obs.obs_data_get_int(settings, "far_left_position_x")
    far_right_position_x = obs.obs_data_get_int(settings, "far_right_position_x")
    calculate_canvas_width()
end

-- Set default values
function script_defaults(settings)
    obs.obs_data_set_default_int(settings, "screen_width", 2560)
    obs.obs_data_set_default_int(settings, "screen_height", 1440)
    obs.obs_data_set_default_int(settings, "canvas_height", 2160)
    obs.obs_data_set_default_int(settings, "center_position_x", -700)
    obs.obs_data_set_default_int(settings, "far_left_position_x", 0)
    obs.obs_data_set_default_int(settings, "far_right_position_x", -1400)
end

-- Script description
function script_description()
    return "Move a source left and right based on mouse position for a 16:9 recording within a 1:1 canvas."
end

-- Get scene item
function get_scene_item()
    local current_scene_source = obs.obs_frontend_get_current_scene()
    if not current_scene_source then
        print("No current scene")
        return nil
    end

    local current_scene = obs.obs_scene_from_source(current_scene_source)
    if not current_scene then
        print("No scene from source")
        return nil
    end

    local scene_item = obs.obs_scene_find_source(current_scene, source_name)
    obs.obs_source_release(current_scene_source)

    if not scene_item then
        print("No scene item found for source: " .. source_name)
    end

    return scene_item
end

-- Center the source on the canvas
function center_source_on_canvas()
    local item = get_scene_item()
    if item then
        local pos = obs.vec2()
        pos.x = center_position_x -- Center position as specified
        pos.y = 0
        obs.obs_sceneitem_set_pos(item, pos)
        print("Source centered: " .. pos.x .. ", " .. pos.y)
    end
end

-- Track mouse position
function track_mouse_position()
    local mouse_x = get_mouse_pos().x
    local centered_mouse_x = mouse_x - (screen_width / 2)
    
    -- Invert x values and map the mouse position such that at 75% for both ways the screen has already moved 100%
    local normalized_mouse_x = centered_mouse_x / (screen_width / 2)
    if normalized_mouse_x > 0 then
        normalized_mouse_x = normalized_mouse_x / 0.75
    else
        normalized_mouse_x = normalized_mouse_x / 0.75
    end
    normalized_mouse_x = math.min(math.max(normalized_mouse_x, -1), 1)
    
    local canvas_pos_x = center_position_x - (normalized_mouse_x * (center_position_x - far_right_position_x))

    local item = get_scene_item()
    if item then
        local pos = obs.vec2()
        pos.x = canvas_pos_x
        pos.y = 0
        obs.obs_sceneitem_set_pos(item, pos)
        print("Mouse X: " .. mouse_x .. ", Centered Mouse X: " .. centered_mouse_x .. ", Canvas Position X: " .. pos.x)
    end
end

-- Get the current mouse position
function get_mouse_pos()
    local mouse = { x = 0, y = 0 }

    if ffi.os == "Windows" then
        if win_point and ffi.C.GetCursorPos(win_point) ~= 0 then
            mouse.x = win_point[0].x
            mouse.y = win_point[0].y
        end
    elseif ffi.os == "Linux" then
        if x11_lib ~= nil and x11_display ~= nil and x11_root ~= nil and x11_mouse ~= nil then
            if x11_lib.XQueryPointer(x11_display, x11_root, x11_mouse.root_win, x11_mouse.child_win, x11_mouse.root_x, x11_mouse.root_y, x11_mouse.win_x, x11_mouse.win_y, x11_mouse.mask) ~= 0 then
                mouse.x = tonumber(x11_mouse.win_x[0])
                mouse.y = tonumber(x11_mouse.win_y[0])
            end
        end
    elseif ffi.os == "OSX" then
        if osx_lib ~= nil and osx_nsevent ~= nil and osx_mouse_location ~= nil then
            local point = osx_mouse_location(osx_nsevent.class, osx_nsevent.sel)
            mouse.x = point.x
            if monitor_info ~= nil then
                if monitor_info.display_height > 0 then
                    mouse.y = monitor_info.display_height - point.y
                else
                    mouse.y = monitor_info.height - point.y
                end
            end
        end
    end

    return mouse
end

-- Hotkey callback
function on_hotkey_pressed(pressed)
    if pressed then
        script_active = not script_active
        if script_active then
            center_source_on_canvas()
            obs.timer_add(track_mouse_position, 50)
            print("Mouse tracking activated")
        else
            obs.timer_remove(track_mouse_position)
            print("Mouse tracking deactivated")
        end
    end
end

-- Script load function
function script_load(settings)
    hotkey_id = obs.obs_hotkey_register_frontend("toggle_mouse_tracking", "Toggle Mouse Tracking", on_hotkey_pressed)
    local hotkey_save_array = obs.obs_data_get_array(settings, "toggle_mouse_tracking_hotkey")
    obs.obs_hotkey_load(hotkey_id, hotkey_save_array)
    obs.obs_data_array_release(hotkey_save_array)

    -- Calculate canvas width and center the source on the canvas when the script loads
    calculate_canvas_width()
    center_source_on_canvas()
end

-- Script save function
function script_save(settings)
    local hotkey_save_array = obs.obs_hotkey_save(hotkey_id)
    obs.obs_data_set_array(settings, "toggle_mouse_tracking_hotkey", hotkey_save_array)
    obs.obs_data_array_release(hotkey_save_array)
end

-- Script unload function
function script_unload()
    obs.obs_hotkey_unregister(hotkey_id)
end
