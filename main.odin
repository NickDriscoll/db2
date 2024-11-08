package main

import "core:c"
import "core:log"

import "vendor:sdl2"

import vkw "desktop_vulkan_wrapper"
import imgui "odin-imgui"

FRAMES_IN_FLIGHT :: 2

main :: proc() {
    context.logger = log.create_console_logger(.Info)
    log.info("Initializing")

    sdl2.Init({.EVENTS, .VIDEO})
    defer sdl2.Quit()
    log.info("Initialized SDL2")

    // Use SDL2 to dynamically link against the Vulkan loader
    // This allows sdl2.Vulkan_GetVkGetInstanceProcAddr() to return a real address
    if sdl2.Vulkan_LoadLibrary(nil) != 0 {
        log.fatal("Couldn't load Vulkan library.")
    }

    // Initialize graphics device
    init_params := vkw.Init_Parameters {
        app_name = "db2",
        api_version = .Vulkan13,
        frames_in_flight = FRAMES_IN_FLIGHT,
        window_support = true,
        vk_get_instance_proc_addr = sdl2.Vulkan_GetVkGetInstanceProcAddr()
    }
    vgd := vkw.init_vulkan(&init_params)
    
    
    // Make window
    resolution: vkw.int2
    resolution.x = 1920
    resolution.y = 1080
    sdl_windowflags : sdl2.WindowFlags = {.VULKAN,.RESIZABLE}
    sdl_window := sdl2.CreateWindow("db2", sdl2.WINDOWPOS_CENTERED, sdl2.WINDOWPOS_CENTERED, resolution.x, resolution.y, sdl_windowflags)
    defer sdl2.DestroyWindow(sdl_window)

    running := true
    for running {
        //Event handling
        {
            event: sdl2.Event
            for sdl2.PollEvent(&event) {
                log.debugf("Event: %v", event)
                #partial switch (event.type) {
                    case .QUIT: running = false
                }
            }
        }
    }
}