package main

import "core:c"
import "core:log"

import "vendor:sdl2"
import vk "vendor:vulkan"

import vkw "desktop_vulkan_wrapper"
import imgui "odin-imgui"

FRAMES_IN_FLIGHT :: 2

main :: proc() {
    context.logger = log.create_console_logger(.Debug)
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

    // Initialize the state required for rendering to the window
    {
        if !vkw.init_sdl2_window(&vgd, sdl_window) {
            log.fatal("Couldn't init SDL2 surface.")
        }
    }

    // Make main timeline semaphore
    gfx_timeline: vkw.Semaphore_Handle
    {
        info := vkw.Semaphore_Info {
            type = .TIMELINE,
            init_value = 0
        }
        gfx_timeline = vkw.create_semaphore(&vgd, &info)
    }

    //Dear ImGUI init
    imgui_state := imgui_init(&vgd, resolution)
    defer imgui_cleanup(&vgd, &imgui_state)

    gfx_sync_info: vkw.Sync_Info

    running := true
    for running {
        //Event handling
        did_resize := false
        {
            io := imgui.GetIO()
            event: sdl2.Event
            for sdl2.PollEvent(&event) {
                #partial switch (event.type) {
                    case .QUIT: running = false
                    case .WINDOWEVENT: {
                        #partial switch (event.window.event) {
                            case .RESIZED: {
                                did_resize = true
                                resolution = vkw.int2{event.window.data1, event.window.data2}
                                log.debugf("resized to %v", resolution)

                            }
                        }
                    }
                    case .KEYDOWN: {
                        imgui.IO_AddKeyEvent(io, SDL2ToImGuiKey(event.key.keysym.sym), true)
                    }
                    case .KEYUP: {
                        imgui.IO_AddKeyEvent(io, SDL2ToImGuiKey(event.key.keysym.sym), false)
                    }
                    case .MOUSEMOTION: {
                        imgui.IO_AddMousePosEvent(io, f32(event.motion.x), f32(event.motion.y))
                    }
                    case .MOUSEBUTTONDOWN: {
                        imgui.IO_AddMouseButtonEvent(io, SDL2ToImGuiMouseButton(event.button.button), true)
                    }
                    case .MOUSEBUTTONUP: {
                        imgui.IO_AddMouseButtonEvent(io, SDL2ToImGuiMouseButton(event.button.button), false)
                    }
                }
            }
        }
        imgui.NewFrame()

        // Update

        // Handle window resize
        if did_resize {
            //imgui.SetWindowSize(imgui.Vec2{f32(resolution.x), f32(resolution.y)})
            io := imgui.GetIO()
            io.DisplaySize = imgui.Vec2{f32(resolution.x), f32(resolution.y)}
            success := vkw.resize_window(&vgd, resolution)
            if !success do log.error("Failed to resize window")
        }


        imgui.ShowDemoWindow()

        // Render
        {
            // Increment timeline semaphore upon command buffer completion
            append(&gfx_sync_info.signal_ops, vkw.Semaphore_Op {
                semaphore = gfx_timeline,
                value = vgd.frame_count + 1
            })
    
            // Sync point where we wait if there are already two frames in the gfx queue
            if vgd.frame_count >= u64(vgd.frames_in_flight) {
                // Wait on timeline semaphore before starting command buffer execution
                wait_value := vgd.frame_count - u64(vgd.frames_in_flight) + 1
                append(&gfx_sync_info.wait_ops, vkw.Semaphore_Op {
                    semaphore = gfx_timeline,
                    value = wait_value
                })

                // CPU-sync to prevent CPU from getting further ahead than
                // the number of frames in flight
                sem, ok := vkw.get_semaphore(&vgd, gfx_timeline)
                if !ok do log.error("Couldn't find semaphore for CPU-sync")
                info := vk.SemaphoreWaitInfo {
                    sType = .SEMAPHORE_WAIT_INFO,
                    pNext = nil,
                    flags = nil,
                    semaphoreCount = 1,
                    pSemaphores = sem,
                    pValues = &wait_value
                }
                if vk.WaitSemaphores(vgd.device, &info, max(u64)) != .SUCCESS {
                    log.error("Failed to wait for timeline semaphore CPU-side man what")
                }
            }
            
            gfx_cb_idx := vkw.begin_gfx_command_buffer(&vgd)

            // This has to be called once per frame
            vkw.begin_frame(&vgd, gfx_cb_idx)
    
            swapchain_image_idx: u32
            vkw.acquire_swapchain_image(&vgd, &swapchain_image_idx)
            swapchain_image_handle := vgd.swapchain_images[swapchain_image_idx]
    
            // Wait on swapchain image acquire semaphore
            // and signal when we're done drawing on a different semaphore
            append(&gfx_sync_info.wait_ops, vkw.Semaphore_Op {
                semaphore = vgd.acquire_semaphores[vkw.in_flight_idx(&vgd)]
            })
            append(&gfx_sync_info.signal_ops, vkw.Semaphore_Op {
                semaphore = vgd.present_semaphores[vkw.in_flight_idx(&vgd)]
            })
    
            // Memory barrier between image acquire and rendering
            swapchain_vkimage, _ := vkw.get_image_vkhandle(&vgd, swapchain_image_handle)
            vkw.cmd_gfx_pipeline_barriers(&vgd, gfx_cb_idx, {
                vkw.Image_Barrier {
                    src_stage_mask = {.ALL_COMMANDS},
                    src_access_mask = {.MEMORY_READ},
                    dst_stage_mask = {.COLOR_ATTACHMENT_OUTPUT},
                    dst_access_mask = {.MEMORY_WRITE},
                    old_layout = .UNDEFINED,
                    new_layout = .COLOR_ATTACHMENT_OPTIMAL,
                    src_queue_family = vgd.gfx_queue_family,
                    dst_queue_family = vgd.gfx_queue_family,
                    image = swapchain_vkimage,
                    subresource_range = vk.ImageSubresourceRange {
                        aspectMask = {.COLOR},
                        baseMipLevel = 0,
                        levelCount = 1,
                        baseArrayLayer = 0,
                        layerCount = 1
                    }
                }
            })

            framebuffer: vkw.Framebuffer
            framebuffer.color_images[0] = swapchain_image_handle
            framebuffer.resolution.x = u32(resolution.x)
            framebuffer.resolution.y = u32(resolution.y)
            framebuffer.clear_color = {0.0, 0.5, 0.5, 1.0}
            framebuffer.color_load_op = .CLEAR
            vkw.cmd_begin_render_pass(&vgd, gfx_cb_idx, &framebuffer)

            // Set viewport
            vkw.cmd_set_viewport(&vgd, gfx_cb_idx, 0, {
                {
                    x = 0,
                    y = 0,
                    width = f32(resolution.x),
                    height = f32(resolution.y),
                    minDepth = 0.0,
                    maxDepth = 1.0
                }
            })

            // Draw Dear ImGUI
            draw_imgui(&vgd, gfx_cb_idx, &imgui_state)

            vkw.cmd_end_render_pass(&vgd, gfx_cb_idx)
    
            // Memory barrier between rendering and image present
            vkw.cmd_gfx_pipeline_barriers(&vgd, gfx_cb_idx, {
                vkw.Image_Barrier {
                    src_stage_mask = {.COLOR_ATTACHMENT_OUTPUT},
                    src_access_mask = {.MEMORY_WRITE},
                    dst_stage_mask = {.ALL_COMMANDS},
                    dst_access_mask = {.MEMORY_READ},
                    old_layout = .COLOR_ATTACHMENT_OPTIMAL,
                    new_layout = .PRESENT_SRC_KHR,
                    src_queue_family = vgd.gfx_queue_family,
                    dst_queue_family = vgd.gfx_queue_family,
                    image = swapchain_vkimage,
                    subresource_range = vk.ImageSubresourceRange {
                        aspectMask = {.COLOR},
                        baseMipLevel = 0,
                        levelCount = 1,
                        baseArrayLayer = 0,
                        layerCount = 1
                    }
                }
            })

            vkw.submit_gfx_command_buffer(&vgd, gfx_cb_idx, &gfx_sync_info)            
            vkw.present_swapchain_image(&vgd, &swapchain_image_idx)
            
            // Clear sync info for next frame
            vkw.clear_sync_info(&gfx_sync_info)
            vgd.frame_count += 1

        }

        // Reset per-frame allocator
        free_all(context.temp_allocator)
    }
}