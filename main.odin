package main

import "core:c"
import "core:log"
import "core:math/linalg/hlsl"
import "core:os"
import "core:slice"
import "core:strings"

import "vendor:sdl2"
import vk "vendor:vulkan"
import stbi "vendor:stb/image"

import vkw "desktop_vulkan_wrapper"
import hm "desktop_vulkan_wrapper/handlemap"
import imgui "odin-imgui"

FRAMES_IN_FLIGHT :: 2
NULL_OFFSET :: 0xFFFFFFFF

load_gif :: proc(path: string) {
    cpath := strings.unsafe_string_to_cstring(path)


}

main :: proc() {// Parse command-line arguments
    log_level := log.Level.Info
    {
        argc := len(os.args)
        for arg, i in os.args {
            if arg == "--log-level" || arg == "-l" {
                if i + 1 < argc {
                    switch os.args[i + 1] {
                        case "DEBUG": log_level = .Debug
                        case "INFO": log_level = .Info
                        case "WARNING": log_level = .Warning
                        case "ERROR": log_level = .Error
                        case "FATAL": log_level = .Fatal
                        case: log.warnf(
                            "Unrecognized --log-level: %v. Using default (%v)",
                            os.args[i + 1],
                            log_level
                        )
                    }
                }
            }
        }
    }
    context.logger = log.create_console_logger(log_level)
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
    resolution: hlsl.uint2
    resolution.x = 1920
    resolution.y = 1080
    sdl_windowflags : sdl2.WindowFlags = {.VULKAN,.RESIZABLE}
    sdl_window := sdl2.CreateWindow("db2", sdl2.WINDOWPOS_CENTERED, sdl2.WINDOWPOS_CENTERED, i32(resolution.x), i32(resolution.y), sdl_windowflags)
    defer sdl2.DestroyWindow(sdl_window)
    //sdl2.SetWindowOpacity(sdl_window, 0.9)

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
            init_value = 0,
            name = "GFX Timeline"
        }
        gfx_timeline = vkw.create_semaphore(&vgd, &info)
    }

    //Dear ImGUI init
    imgui_state := imgui_init(&vgd, resolution)
    defer imgui_cleanup(&vgd, &imgui_state)
    
    files_to_load := make([dynamic]string, allocator = context.allocator)
    defer delete(files_to_load)
    loaded_images := make([dynamic]vkw.Image_Handle, len = 0, cap = 64, allocator = context.allocator)
    defer delete(loaded_images)

    gfx_sync_info: vkw.Sync_Info

    running := true
    for running {
        //Event handling
        did_resize := false
        {
            io := imgui.GetIO()
            event: sdl2.Event
            for sdl2.PollEvent(&event) {
            //for sdl2.WaitEvent(&event) {
                #partial switch (event.type) {
                    case .QUIT: running = false
                    case .WINDOWEVENT: {
                        #partial switch (event.window.event) {
                            case .RESIZED: {
                                did_resize = true
                                resolution = hlsl.uint2{u32(event.window.data1), u32(event.window.data2)}
                                log.debugf("resized to %v", resolution)

                            }
                        }
                    }
                    case .DROPFILE: {
                        log.infof("Opening image: \"%v\"", event.drop.file)
                        append(&files_to_load, string(event.drop.file))
                    }
                    case .KEYDOWN: {
                        log.debugf("%v", event.key)
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
                    case .MOUSEWHEEL: {
                        imgui.IO_AddMouseWheelEvent(io, f32(event.wheel.x), f32(event.wheel.y))
                    }
                }
            }
        }
        imgui.NewFrame()

        // Update

        // Load requested images
        for len(files_to_load) > 0 {
            filepath := pop(&files_to_load)

            handle: vkw.Image_Handle
            if filepath[len(filepath)-3:] == "gif" {
                file_bytes, ok := os.read_entire_file(filepath)
                if !ok {
                    log.error("Failed to read entire file.")
                }

                delays: [^]c.int
                x, y: c.int
                frame_count: c.int
                comp: c.int
                req_comp : c.int = 4
                gif_bytes := stbi.load_gif_from_memory(&file_bytes[0], i32(len(file_bytes)), &delays, &x, &y, &frame_count, &comp, req_comp)

                

            } else {
                filename := strings.unsafe_string_to_cstring(filepath)
                width, height, channels: i32
                image_bytes := stbi.load(filename, &width, &height, &channels, 4)
                defer stbi.image_free(image_bytes)
    
                byte_count := int(width * height * 4)
                image_slice := slice.from_ptr(image_bytes, byte_count)
                log.debugf("%v uncompressed size: %v bytes", filename, byte_count)
        
                info := vkw.Image_Create {
                    flags = nil,
                    image_type = .D2,
                    format = .R8G8B8A8_SRGB,
                    extent = {
                        width = u32(width),
                        height = u32(height),
                        depth = 1
                    },
                    supports_mipmaps = false,
                    array_layers = 1,
                    samples = {._1},
                    tiling = .OPTIMAL,
                    usage = {.SAMPLED,.TRANSFER_DST},
                    alloc_flags = nil
                }
                ok: bool
                handle, ok = vkw.sync_create_image_with_data(&vgd, &info, image_slice)
                if !ok {
                    log.error("vkw.sync_create_image_with_data failed.")
                    continue
                }
            }


            append(&loaded_images, handle)
            break
        }

        // pixels_sum: u64
        // for filepath in files_to_load {
        //     filename := strings.unsafe_string_to_cstring(filepath)
        //     x, y, comp: c.int
        //     stbi.info(filename, &x, &y, &comp)
        //     pixels_sum += u64(x + y)
        // }
        // if pixels_sum > 0 do log.infof("Total pixels: %v", pixels_sum)

        // Handle window resize
        if did_resize {
            io := imgui.GetIO()
            io.DisplaySize = imgui.Vec2{f32(resolution.x), f32(resolution.y)}
            success := vkw.resize_window(&vgd, resolution)
            if !success do log.error("Failed to resize window")
        }

        main_window_flags := imgui.WindowFlags {
            .NoTitleBar,
            .NoMove,
            //.NoBackground,
            .NoResize
        }
        if imgui.Begin("Main window", flags = main_window_flags) {
            imgui.SetWindowPos({0, 0})
            imgui.SetWindowSize({f32(resolution.x), f32(resolution.y)})

            if imgui.Button("Clear") {
                for handle in loaded_images {
                    vkw.delete_image(&vgd, handle)
                }
                clear(&loaded_images)
            }
            imgui.Separator()

            // Start child window which will hold the images
            if imgui.BeginChild("Images") {
                // Display loaded images
                for image_handle, i in loaded_images {
                    image, ok := vkw.get_image(&vgd, image_handle)
                    if !ok {
                        log.warn("Couldn't fetch image from handle: %v", image_handle)
                        continue
                    }
    
                    images_per_row := 3
                    if !(i % images_per_row == 0) do imgui.SameLine()
    
                    display_width := f32(resolution.x) / f32(images_per_row)
                    display_height := display_width * f32(image.extent.height) / f32(image.extent.width)
        
                    imgui.Image(hm.handle_to_rawptr(image_handle), {display_width, display_height})
                }

                imgui.EndChild()
            }
        }
        imgui.End()

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
                    pValues = &wait_value,
                }
                if vk.WaitSemaphores(vgd.device, &info, max(u64)) != .SUCCESS {
                    log.error("Failed to wait for timeline semaphore CPU-side man what")
                }
            }
            
            // Begin command buffer recording
            gfx_cb_idx := vkw.begin_gfx_command_buffer(&vgd, &gfx_sync_info, gfx_timeline)
    
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
            framebuffer.color_load_op = .CLEAR
            framebuffer.depth_image = { index = NULL_OFFSET }
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
            render_imgui(&vgd, gfx_cb_idx, &imgui_state)

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