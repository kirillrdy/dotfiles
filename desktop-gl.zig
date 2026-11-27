//! GPU compositing for the native compositor: GLES 2 through EGL on GBM
//! buffers that the DRM backend scans out. Surfaces are drawn as textured
//! quads with premultiplied alpha, as wlroots' GLES renderer draws them.
const std = @import("std");

pub const Error = error{ NoGbm, NoEgl, NoContext, NoShaders, NoSurface, OutOfMemory };

// ------------------------------------------------------------------ GBM

pub const GbmDevice = opaque {};
pub const GbmSurface = opaque {};
pub const GbmBo = opaque {};

pub const gbm_format_xrgb8888: u32 = 0x34325258; // fourcc 'XR24'
pub const gbm_bo_use_scanout: u32 = 1 << 0;
pub const gbm_bo_use_rendering: u32 = 1 << 2;

pub extern fn gbm_create_device(fd: c_int) ?*GbmDevice;
pub extern fn gbm_device_destroy(*GbmDevice) void;
pub extern fn gbm_surface_create(*GbmDevice, width: u32, height: u32, format: u32, flags: u32) ?*GbmSurface;
pub extern fn gbm_surface_destroy(*GbmSurface) void;
pub extern fn gbm_surface_lock_front_buffer(*GbmSurface) ?*GbmBo;
pub extern fn gbm_surface_release_buffer(*GbmSurface, *GbmBo) void;
/// Returns union gbm_bo_handle, eight bytes returned in a register.
pub extern fn gbm_bo_get_handle(*GbmBo) u64;
pub extern fn gbm_bo_get_stride(*GbmBo) u32;
pub extern fn gbm_bo_get_width(*GbmBo) u32;
pub extern fn gbm_bo_get_height(*GbmBo) u32;
pub extern fn gbm_bo_get_format(*GbmBo) u32;
pub extern fn gbm_bo_get_modifier(*GbmBo) u64;
pub extern fn gbm_bo_get_plane_count(*GbmBo) c_int;
/// Returns union gbm_bo_handle for one plane, eight bytes returned in a register.
pub extern fn gbm_bo_get_handle_for_plane(*GbmBo, plane: c_int) u64;
pub extern fn gbm_bo_get_stride_for_plane(*GbmBo, plane: c_int) u32;
pub extern fn gbm_bo_get_offset(*GbmBo, plane: c_int) u32;
pub extern fn gbm_bo_set_user_data(*GbmBo, data: ?*anyopaque, destroy: ?*const fn (*GbmBo, ?*anyopaque) callconv(.c) void) void;
pub extern fn gbm_bo_get_user_data(*GbmBo) ?*anyopaque;

// ------------------------------------------------------------------ EGL

pub const EGLDisplay = ?*anyopaque;
pub const EGLConfig = ?*anyopaque;
pub const EGLContext = ?*anyopaque;
pub const EGLSurface = ?*anyopaque;
pub const EGLImage = ?*anyopaque;

pub const egl = struct {
    pub const platform_gbm: u32 = 0x31D7;
    pub const opengl_es_api: u32 = 0x30A0;
    pub const none: i32 = 0x3038;
    pub const surface_type: i32 = 0x3033;
    pub const window_bit: i32 = 0x0004;
    pub const renderable_type: i32 = 0x3040;
    pub const opengl_es2_bit: i32 = 0x0004;
    pub const red_size: i32 = 0x3024;
    pub const green_size: i32 = 0x3023;
    pub const blue_size: i32 = 0x3022;
    pub const alpha_size: i32 = 0x3021;
    pub const native_visual_id: i32 = 0x302E;
    pub const context_client_version: i32 = 0x3098;
    pub const extensions: i32 = 0x3055;
    pub const buffer_age: i32 = 0x313D;
    pub const sync_native_fence: u32 = 0x3144;
    pub const sync_native_fence_fd: isize = 0x3145;
    pub const linux_dma_buf: u32 = 0x3270;
    pub const width: i32 = 0x3057;
    pub const height: i32 = 0x3056;
    pub const linux_drm_fourcc: i32 = 0x3271;
    pub const plane_attributes = [4][5]i32{
        // fd, offset, pitch, modifier low, modifier high
        .{ 0x3272, 0x3273, 0x3274, 0x3443, 0x3444 },
        .{ 0x3275, 0x3276, 0x3277, 0x3445, 0x3446 },
        .{ 0x3278, 0x3279, 0x327A, 0x3447, 0x3448 },
        .{ 0x3440, 0x3441, 0x3442, 0x3449, 0x344A },
    };
};

pub extern fn eglGetPlatformDisplay(platform: u32, native: ?*anyopaque, attributes: ?[*]const isize) EGLDisplay;
pub extern fn eglInitialize(EGLDisplay, major: ?*i32, minor: ?*i32) u32;
pub extern fn eglTerminate(EGLDisplay) u32;
pub extern fn eglBindAPI(api: u32) u32;
pub extern fn eglChooseConfig(EGLDisplay, attributes: [*]const i32, configs: [*]EGLConfig, size: i32, count: *i32) u32;
pub extern fn eglGetConfigAttrib(EGLDisplay, EGLConfig, attribute: i32, value: *i32) u32;
pub extern fn eglCreateContext(EGLDisplay, EGLConfig, share: EGLContext, attributes: [*]const i32) EGLContext;
pub extern fn eglDestroyContext(EGLDisplay, EGLContext) u32;
pub extern fn eglCreatePlatformWindowSurface(EGLDisplay, EGLConfig, native: ?*anyopaque, attributes: ?[*]const isize) EGLSurface;
pub extern fn eglDestroySurface(EGLDisplay, EGLSurface) u32;
pub extern fn eglMakeCurrent(EGLDisplay, draw: EGLSurface, read: EGLSurface, EGLContext) u32;
pub extern fn eglSwapBuffers(EGLDisplay, EGLSurface) u32;
pub extern fn eglQueryString(EGLDisplay, name: i32) ?[*:0]const u8;
pub extern fn eglGetProcAddress(name: [*:0]const u8) ?*const anyopaque;
pub extern fn eglGetError() i32;
pub extern fn eglQuerySurface(EGLDisplay, EGLSurface, attribute: i32, value: *i32) u32;
pub extern fn eglCreateImage(EGLDisplay, EGLContext, target: u32, buffer: ?*anyopaque, attributes: [*]const isize) EGLImage;
pub const EGLSync = ?*anyopaque;
pub extern fn eglCreateSync(EGLDisplay, kind: u32, attributes: ?[*]const isize) EGLSync;
pub extern fn eglDestroySync(EGLDisplay, EGLSync) u32;
pub extern fn eglWaitSync(EGLDisplay, EGLSync, flags: i32) u32;
/// eglDupNativeFenceFDANDROID, from EGL_ANDROID_native_fence_sync.
const DupNativeFence = *const fn (EGLDisplay, EGLSync) callconv(.c) i32;
pub extern fn eglDestroyImage(EGLDisplay, EGLImage) u32;

// ------------------------------------------------------------------ GLES 2

pub const gl = struct {
    pub const texture_2d: u32 = 0x0DE1;
    pub const texture0: u32 = 0x84C0;
    pub const texture_min_filter: u32 = 0x2801;
    pub const texture_mag_filter: u32 = 0x2800;
    pub const texture_wrap_s: u32 = 0x2802;
    pub const texture_wrap_t: u32 = 0x2803;
    pub const linear: i32 = 0x2601;
    pub const clamp_to_edge: i32 = 0x812F;
    pub const bgra_ext: u32 = 0x80E1;
    pub const unsigned_byte: u32 = 0x1401;
    pub const float: u32 = 0x1406;
    pub const triangle_strip: u32 = 0x0005;
    pub const color_buffer_bit: u32 = 0x4000;
    pub const blend: u32 = 0x0BE2;
    pub const scissor_test: u32 = 0x0C11;
    pub const one: u32 = 1;
    pub const one_minus_src_alpha: u32 = 0x0303;
    pub const vertex_shader: u32 = 0x8B31;
    pub const fragment_shader: u32 = 0x8B30;
    pub const compile_status: u32 = 0x8B81;
    pub const link_status: u32 = 0x8B82;
    pub const unpack_alignment: u32 = 0x0CF5;
    pub const pack_alignment: u32 = 0x0D05;
    pub const framebuffer: u32 = 0x8D40;
    pub const color_attachment0: u32 = 0x8CE0;
    pub const framebuffer_complete: u32 = 0x8CD5;
    pub const rgba: u32 = 0x1908;
    pub const renderer: u32 = 0x1F01;
    pub const extensions: u32 = 0x1F03;
};

pub extern fn glGetString(name: u32) ?[*:0]const u8;
pub extern fn glCreateShader(kind: u32) u32;
pub extern fn glShaderSource(shader: u32, count: i32, sources: [*]const [*:0]const u8, lengths: ?[*]const i32) void;
pub extern fn glCompileShader(shader: u32) void;
pub extern fn glGetShaderiv(shader: u32, name: u32, value: *i32) void;
pub extern fn glDeleteShader(shader: u32) void;
pub extern fn glCreateProgram() u32;
pub extern fn glAttachShader(program: u32, shader: u32) void;
pub extern fn glLinkProgram(program: u32) void;
pub extern fn glGetProgramiv(program: u32, name: u32, value: *i32) void;
pub extern fn glUseProgram(program: u32) void;
pub extern fn glDeleteProgram(program: u32) void;
pub extern fn glGetUniformLocation(program: u32, name: [*:0]const u8) i32;
pub extern fn glGetAttribLocation(program: u32, name: [*:0]const u8) i32;
pub extern fn glUniform1i(location: i32, value: i32) void;
pub extern fn glUniform1f(location: i32, value: f32) void;
pub extern fn glUniform2f(location: i32, x: f32, y: f32) void;
pub extern fn glUniform3f(location: i32, x: f32, y: f32, z: f32) void;
pub extern fn glUniform4f(location: i32, x: f32, y: f32, z: f32, w: f32) void;
pub extern fn glVertexAttribPointer(index: u32, size: i32, kind: u32, normalized: u8, stride: i32, pointer: ?*const anyopaque) void;
pub extern fn glEnableVertexAttribArray(index: u32) void;
pub extern fn glGenTextures(count: i32, textures: [*]u32) void;
pub extern fn glDeleteTextures(count: i32, textures: [*]const u32) void;
pub extern fn glBindTexture(target: u32, texture: u32) void;
pub extern fn glActiveTexture(unit: u32) void;
pub extern fn glTexParameteri(target: u32, name: u32, value: i32) void;
pub extern fn glTexImage2D(target: u32, level: i32, internal: i32, width: i32, height: i32, border: i32, format: u32, kind: u32, pixels: ?*const anyopaque) void;
pub extern fn glPixelStorei(name: u32, value: i32) void;
pub extern fn glViewport(x: i32, y: i32, width: i32, height: i32) void;
pub extern fn glScissor(x: i32, y: i32, width: i32, height: i32) void;
pub extern fn glClearColor(r: f32, g: f32, b: f32, a: f32) void;
pub extern fn glClear(mask: u32) void;
pub extern fn glEnable(cap: u32) void;
pub extern fn glDisable(cap: u32) void;
pub extern fn glBlendFunc(source: u32, destination: u32) void;
pub extern fn glDrawArrays(mode: u32, first: i32, count: i32) void;
pub extern fn glFlush() void;
pub extern fn glGenFramebuffers(count: i32, framebuffers: [*]u32) void;
pub extern fn glDeleteFramebuffers(count: i32, framebuffers: [*]const u32) void;
pub extern fn glBindFramebuffer(target: u32, framebuffer: u32) void;
pub extern fn glFramebufferTexture2D(target: u32, attachment: u32, texture_target: u32, texture: u32, level: i32) void;
pub extern fn glCheckFramebufferStatus(target: u32) u32;
pub extern fn glReadPixels(x: i32, y: i32, width: i32, height: i32, format: u32, kind: u32, pixels: ?*anyopaque) void;

/// eglQueryDmaBufFormatsEXT and eglQueryDmaBufModifiersEXT.
const QueryFormats = *const fn (EGLDisplay, max: i32, formats: ?[*]i32, count: *i32) callconv(.c) u32;
const QueryModifiers = *const fn (EGLDisplay, format: i32, max: i32, modifiers: ?[*]u64, external_only: ?[*]u32, count: *i32) callconv(.c) u32;

/// A buffer format clients may share, with its layout modifier.
pub const FormatModifier = extern struct { format: u32, pad: u32 = 0, modifier: u64 };
/// DRM_FORMAT_MOD_INVALID: the driver's implicit layout.
pub const modifier_invalid: u64 = 0x00ffffffffffffff;

/// One plane of a dmabuf, as zwp_linux_buffer_params_v1.add describes it.
pub const Plane = struct { fd: i32, offset: u32, stride: u32, modifier: u64 };

/// glEGLImageTargetTexture2DOES, from GL_OES_EGL_image.
const ImageTargetTexture = *const fn (target: u32, image: EGLImage) callconv(.c) void;

// ------------------------------------------------------------------ Renderer

const vertex_source =
    \\attribute vec2 position;
    \\uniform vec4 rect;
    \\uniform vec2 viewport;
    \\uniform vec3 out_x;
    \\uniform vec3 out_y;
    \\uniform vec2 uv_origin;
    \\uniform vec2 uv_x;
    \\uniform vec2 uv_y;
    \\varying vec2 uv;
    \\void main() {
    \\    vec2 pixel = rect.xy + position * rect.zw;
    \\    vec3 scene = vec3(pixel / viewport, 1.0);
    \\    vec2 shown = vec2(dot(out_x, scene), dot(out_y, scene));
    \\    gl_Position = vec4(shown.x * 2.0 - 1.0, 1.0 - shown.y * 2.0, 0.0, 1.0);
    \\    uv = uv_origin + position.x * uv_x + position.y * uv_y;
    \\}
;

const fragment_source =
    \\precision mediump float;
    \\varying vec2 uv;
    \\uniform sampler2D texture;
    \\uniform float opacity;
    \\uniform float opaque;
    \\void main() {
    \\    vec4 color = texture2D(texture, uv);
    \\    if (opaque > 0.5) color.a = 1.0;
    \\    gl_FragColor = color * opacity;
    \\}
;

const quad = [_]f32{ 0, 0, 1, 0, 0, 1, 1, 1 };

/// A rectangle in output pixels, as raster.Rect.
pub const Rect = struct { x: f64, y: f64, width: f64, height: f64 };
pub const Clip = struct { x: i32, y: i32, width: i32, height: i32 };

/// A wl_output transform as an affine map of normalized coordinates: the
/// point q of the upright picture is at (a*qx + b*qy + c, d*qx + e*qy + f)
/// of a buffer holding it turned counter-clockwise (flipping first).
pub fn transformMatrix(transform: u32) [6]f64 {
    return switch (transform) {
        1 => .{ 0, 1, 0, -1, 0, 1 },
        2 => .{ -1, 0, 1, 0, -1, 1 },
        3 => .{ 0, -1, 1, 1, 0, 0 },
        4 => .{ -1, 0, 1, 0, 1, 0 },
        5 => .{ 0, 1, 0, 1, 0, 0 },
        6 => .{ 1, 0, 0, 0, -1, 1 },
        7 => .{ 0, -1, 1, -1, 0, 1 },
        else => .{ 1, 0, 0, 0, 1, 0 },
    };
}

/// Where the quad's corners sample the texture: the top-left corner samples
/// `origin`, and moving right or down across the quad moves by `x` or `y`.
/// It expresses a crop combined with any of the eight buffer transforms.
pub const UvMap = struct {
    origin: [2]f32 = .{ 0, 0 },
    x: [2]f32 = .{ 1, 0 },
    y: [2]f32 = .{ 0, 1 },

    pub const identity: UvMap = .{};
};

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    gbm: *GbmDevice,
    display: EGLDisplay,
    config: EGLConfig,
    context: EGLContext,
    program: u32,
    rect_location: i32,
    viewport_location: i32,
    opacity_location: i32,
    opaque_location: i32,
    uv_locations: [3]i32,
    out_locations: [2]i32,
    /// The scanout buffer's size, and how the scene maps onto it.
    target_size: [2]f32 = .{ 1, 1 },
    transform: [6]f32 = .{ 1, 0, 0, 0, 1, 0 },
    position: u32,
    /// A texture for images drawn once, such as overview previews.
    scratch: u32 = 0,
    image_target: ?ImageTargetTexture = null,
    /// The size of the target being drawn, in pixels.
    viewport: [2]f32 = .{ 1, 1 },
    /// The part of the frame being redrawn; drawing outside it is clipped.
    frame_clip: ?Clip = null,
    blending: bool = false,
    buffer_age: bool = false,
    /// Fences shared with the kernel (EGL_ANDROID_native_fence_sync), and the
    /// fence of the last frame: released buffers signal when it does.
    dup_fence: ?DupNativeFence = null,
    last_fence: i32 = -1,
    name_buffer: [128]u8 = undefined,
    name_len: usize = 0,

    /// Opens EGL on the card's GBM device; fails where no GPU driver loads.
    pub fn init(allocator: std.mem.Allocator, card_fd: i32) Error!*Renderer {
        const device = gbm_create_device(card_fd) orelse return error.NoGbm;
        errdefer gbm_device_destroy(device);
        const display = eglGetPlatformDisplay(egl.platform_gbm, device, null);
        if (display == null) return error.NoEgl;
        if (eglInitialize(display, null, null) == 0) return error.NoEgl;
        errdefer _ = eglTerminate(display);
        if (eglBindAPI(egl.opengl_es_api) == 0) return error.NoEgl;
        const config = chooseConfig(display) orelse return error.NoEgl;
        const context_attributes = [_]i32{ egl.context_client_version, 2, egl.none };
        const context = eglCreateContext(display, config, null, &context_attributes);
        if (context == null) return error.NoContext;
        errdefer _ = eglDestroyContext(display, context);
        // GL calls need a current context; surfaceless until a target is drawn.
        if (eglMakeCurrent(display, null, null, context) == 0) return error.NoContext;
        errdefer _ = eglMakeCurrent(display, null, null, null);
        const program = try link();
        errdefer glDeleteProgram(program);
        const self = try allocator.create(Renderer);
        self.* = .{
            .allocator = allocator,
            .gbm = device,
            .display = display,
            .config = config,
            .context = context,
            .program = program,
            .rect_location = glGetUniformLocation(program, "rect"),
            .viewport_location = glGetUniformLocation(program, "viewport"),
            .opacity_location = glGetUniformLocation(program, "opacity"),
            .opaque_location = glGetUniformLocation(program, "opaque"),
            .uv_locations = .{ glGetUniformLocation(program, "uv_origin"), glGetUniformLocation(program, "uv_x"), glGetUniformLocation(program, "uv_y") },
            .out_locations = .{ glGetUniformLocation(program, "out_x"), glGetUniformLocation(program, "out_y") },
            .position = @intCast(@max(0, glGetAttribLocation(program, "position"))),
        };
        if (glGetString(gl.renderer)) |driver| {
            const text = std.mem.span(driver);
            self.name_len = @min(text.len, self.name_buffer.len);
            @memcpy(self.name_buffer[0..self.name_len], text[0..self.name_len]);
        }
        if (eglGetProcAddress("glEGLImageTargetTexture2DOES")) |address| self.image_target = @ptrCast(address);
        self.buffer_age = self.hasExtension("EGL_EXT_buffer_age");
        if (self.hasExtension("EGL_ANDROID_native_fence_sync")) if (eglGetProcAddress("eglDupNativeFenceFDANDROID")) |address| {
            self.dup_fence = @ptrCast(address);
        };
        self.scratch = createTexture();
        return self;
    }

    pub fn deinit(self: *Renderer) void {
        if (self.last_fence >= 0) _ = std.c.close(self.last_fence);
        glDeleteTextures(1, @ptrCast(&self.scratch));
        glDeleteProgram(self.program);
        _ = eglMakeCurrent(self.display, null, null, null);
        _ = eglDestroyContext(self.display, self.context);
        _ = eglTerminate(self.display);
        gbm_device_destroy(self.gbm);
        self.allocator.destroy(self);
    }

    /// The GL driver's name, such as "Mesa Intel(R) Graphics (LNL)".
    pub fn name(self: *const Renderer) []const u8 {
        return self.name_buffer[0..self.name_len];
    }

    /// An XRGB8888 window config, as scanout buffers use.
    fn chooseConfig(display: EGLDisplay) EGLConfig {
        const attributes = [_]i32{ egl.surface_type, egl.window_bit, egl.renderable_type, egl.opengl_es2_bit, egl.red_size, 8, egl.green_size, 8, egl.blue_size, 8, egl.alpha_size, 0, egl.none };
        var configs: [64]EGLConfig = undefined;
        var count: i32 = 0;
        if (eglChooseConfig(display, &attributes, &configs, configs.len, &count) == 0) return null;
        for (configs[0..@intCast(count)]) |config| {
            var visual: i32 = 0;
            if (eglGetConfigAttrib(display, config, egl.native_visual_id, &visual) != 0 and @as(u32, @bitCast(visual)) == gbm_format_xrgb8888) return config;
        }
        return null;
    }

    fn compile(kind: u32, source: [*:0]const u8) Error!u32 {
        const shader = glCreateShader(kind);
        const sources = [_][*:0]const u8{source};
        glShaderSource(shader, 1, &sources, null);
        glCompileShader(shader);
        var ok: i32 = 0;
        glGetShaderiv(shader, gl.compile_status, &ok);
        if (ok == 0) {
            glDeleteShader(shader);
            return error.NoShaders;
        }
        return shader;
    }

    fn link() Error!u32 {
        const vertex = try compile(gl.vertex_shader, vertex_source);
        defer glDeleteShader(vertex);
        const fragment = try compile(gl.fragment_shader, fragment_source);
        defer glDeleteShader(fragment);
        const program = glCreateProgram();
        glAttachShader(program, vertex);
        glAttachShader(program, fragment);
        glLinkProgram(program);
        var ok: i32 = 0;
        glGetProgramiv(program, gl.link_status, &ok);
        if (ok == 0) {
            glDeleteProgram(program);
            return error.NoShaders;
        }
        return program;
    }

    pub fn createTexture() u32 {
        var texture: u32 = 0;
        glGenTextures(1, @ptrCast(&texture));
        glBindTexture(gl.texture_2d, texture);
        glTexParameteri(gl.texture_2d, gl.texture_min_filter, gl.linear);
        glTexParameteri(gl.texture_2d, gl.texture_mag_filter, gl.linear);
        glTexParameteri(gl.texture_2d, gl.texture_wrap_s, gl.clamp_to_edge);
        glTexParameteri(gl.texture_2d, gl.texture_wrap_t, gl.clamp_to_edge);
        return texture;
    }

    pub fn deleteTexture(_: *Renderer, texture: u32) void {
        if (texture != 0) glDeleteTextures(1, @ptrCast(&texture));
    }

    /// Uploads premultiplied ARGB pixels (BGRA bytes) into `texture`.
    pub fn upload(_: *Renderer, texture: u32, pixels: []const u32, width: u32, height: u32) void {
        glBindTexture(gl.texture_2d, texture);
        glPixelStorei(gl.unpack_alignment, 4);
        glTexImage2D(gl.texture_2d, 0, @intCast(gl.bgra_ext), @intCast(width), @intCast(height), 0, gl.bgra_ext, gl.unsigned_byte, pixels.ptr);
    }

    /// How many frames old the next buffer's content is: 0 when unknown.
    pub fn bufferAge(self: *Renderer, target: *Target) u32 {
        if (!self.buffer_age) return 0;
        if (eglMakeCurrent(self.display, target.surface, target.surface, self.context) == 0) return 0;
        var age: i32 = 0;
        if (eglQuerySurface(self.display, target.surface, egl.buffer_age, &age) == 0) return 0;
        return @intCast(@max(0, age));
    }

    /// Starts drawing into `target`, cleared to opaque `background` (ARGB).
    /// With `damage`, only that part is cleared and drawn; the rest keeps
    /// the buffer's previous content.
    /// The scene is drawn upright and turned by `transform` (a wl_output
    /// transform) into the buffer; quarter turns swap the scene's sides.
    pub fn begin(self: *Renderer, target: *Target, background: u32, damage: ?Clip, transform: u32) bool {
        if (eglMakeCurrent(self.display, target.surface, target.surface, self.context) == 0) return false;
        self.target_size = .{ @floatFromInt(target.width), @floatFromInt(target.height) };
        self.viewport = if (transform & 1 != 0) .{ self.target_size[1], self.target_size[0] } else self.target_size;
        const m = transformMatrix(transform);
        for (&self.transform, m) |*out, value| out.* = @floatCast(value);
        glViewport(0, 0, @intCast(target.width), @intCast(target.height));
        self.frame_clip = damage;
        if (self.scissor(null)) {
            const channel = struct {
                fn of(color: u32, shift: u5) f32 {
                    return @as(f32, @floatFromInt((color >> shift) & 0xff)) / 255.0;
                }
            };
            glClearColor(channel.of(background, 16), channel.of(background, 8), channel.of(background, 0), 1);
            glClear(gl.color_buffer_bit);
        }
        glUseProgram(self.program);
        self.glUniformViewport();
        glEnable(gl.blend);
        self.blending = true;
        glBlendFunc(gl.one, gl.one_minus_src_alpha);
        glActiveTexture(gl.texture0);
        glVertexAttribPointer(self.position, 2, gl.float, 0, 0, &quad);
        glEnableVertexAttribArray(self.position);
        return true;
    }

    /// Draws `texture` stretched over `rect`, optionally clipped and faded.
    pub fn draw(self: *Renderer, texture: u32, rect: Rect, clip: ?Clip, opacity: f32, opaque_alpha: bool) void {
        self.drawMapped(texture, rect, UvMap.identity, clip, opacity, opaque_alpha);
    }

    /// Draws `texture` over `rect`, sampling it through `uv`.
    pub fn drawMapped(self: *Renderer, texture: u32, rect: Rect, uv: UvMap, clip: ?Clip, opacity: f32, opaque_alpha: bool) void {
        if (!self.scissor(clip)) return;
        const need_blend = !opaque_alpha or opacity < 1.0;
        if (need_blend != self.blending) {
            if (need_blend) glEnable(gl.blend) else glDisable(gl.blend);
            self.blending = need_blend;
        }
        glUniform2f(self.uv_locations[0], uv.origin[0], uv.origin[1]);
        glUniform2f(self.uv_locations[1], uv.x[0], uv.x[1]);
        glUniform2f(self.uv_locations[2], uv.y[0], uv.y[1]);
        glBindTexture(gl.texture_2d, texture);
        glUniform4f(self.rect_location, @floatCast(rect.x), @floatCast(rect.y), @floatCast(rect.width), @floatCast(rect.height));
        glUniform1f(self.opacity_location, opacity);
        glUniform1f(self.opaque_location, if (opaque_alpha) 1 else 0);
        glDrawArrays(gl.triangle_strip, 0, 4);
    }

    /// Limits drawing to `clip` within the frame's damage; false when nothing is left.
    fn scissor(self: *Renderer, clip: ?Clip) bool {
        var box = clip orelse self.frame_clip orelse {
            glDisable(gl.scissor_test);
            return true;
        };
        if (clip != null) if (self.frame_clip) |frame| {
            const left = @max(box.x, frame.x);
            const top = @max(box.y, frame.y);
            const right = @min(box.x + box.width, frame.x + frame.width);
            const bottom = @min(box.y + box.height, frame.y + frame.height);
            box = .{ .x = left, .y = top, .width = right - left, .height = bottom - top };
        };
        if (box.width <= 0 or box.height <= 0) return false;
        // The scene box, turned into buffer pixels.
        const m = self.transform;
        var lo = [2]f32{ std.math.floatMax(f32), std.math.floatMax(f32) };
        var hi = [2]f32{ -std.math.floatMax(f32), -std.math.floatMax(f32) };
        for ([_][2]f32{ .{ @floatFromInt(box.x), @floatFromInt(box.y) }, .{ @floatFromInt(box.x + box.width), @floatFromInt(box.y + box.height) } }) |corner| {
            const qx = corner[0] / self.viewport[0];
            const qy = corner[1] / self.viewport[1];
            const bx = (m[0] * qx + m[1] * qy + m[2]) * self.target_size[0];
            const by = (m[3] * qx + m[4] * qy + m[5]) * self.target_size[1];
            lo = .{ @min(lo[0], bx), @min(lo[1], by) };
            hi = .{ @max(hi[0], bx), @max(hi[1], by) };
        }
        const x: i32 = @intFromFloat(@floor(lo[0]));
        const y: i32 = @intFromFloat(@floor(lo[1]));
        const w: i32 = @intFromFloat(@ceil(hi[0]) - @floor(lo[0]));
        const h: i32 = @intFromFloat(@ceil(hi[1]) - @floor(lo[1]));
        glEnable(gl.scissor_test);
        // Scissor boxes count from the bottom row.
        glScissor(x, @as(i32, @intFromFloat(self.target_size[1])) - y - h, w, h);
        return true;
    }

    fn glUniformViewport(self: *Renderer) void {
        glUniform2f(self.viewport_location, self.viewport[0], self.viewport[1]);
        const m = self.transform;
        glUniform3f(self.out_locations[0], m[0], m[1], m[2]);
        glUniform3f(self.out_locations[1], m[3], m[4], m[5]);
    }

    /// Draws CPU pixels once, through the scratch texture.
    pub fn drawPixels(self: *Renderer, pixels: []const u32, width: u32, height: u32, rect: Rect, clip: ?Clip, opacity: f32) void {
        self.upload(self.scratch, pixels, width, height);
        self.draw(self.scratch, rect, clip, opacity, false);
    }

    /// The formats and modifiers clients' GPU buffers may use: what EGL can
    /// import into a 2D texture, plus each format's implicit layout.
    pub fn dmabufFormats(self: *Renderer, allocator: std.mem.Allocator) ![]FormatModifier {
        var list: std.ArrayList(FormatModifier) = .empty;
        errdefer list.deinit(allocator);
        if (!self.hasExtension("EGL_EXT_image_dma_buf_import")) return list.toOwnedSlice(allocator);
        const query_formats: ?QueryFormats = if (eglGetProcAddress("eglQueryDmaBufFormatsEXT")) |p| @ptrCast(p) else null;
        const query_modifiers: ?QueryModifiers = if (eglGetProcAddress("eglQueryDmaBufModifiersEXT")) |p| @ptrCast(p) else null;
        if (query_formats == null or query_modifiers == null or !self.hasExtension("EGL_EXT_image_dma_buf_import_modifiers")) {
            // Without modifiers, the common formats in their implicit layout.
            for ([_]u32{ 0x34325241, 0x34325258, 0x34324241, 0x34324258 }) |format| try list.append(allocator, .{ .format = format, .modifier = modifier_invalid });
            return list.toOwnedSlice(allocator);
        }
        var count: i32 = 0;
        if (query_formats.?(self.display, 0, null, &count) == 0 or count <= 0) return list.toOwnedSlice(allocator);
        const formats = try allocator.alloc(i32, @intCast(count));
        defer allocator.free(formats);
        _ = query_formats.?(self.display, count, formats.ptr, &count);
        for (formats[0..@intCast(count)]) |format| {
            var modifier_count: i32 = 0;
            _ = query_modifiers.?(self.display, format, 0, null, null, &modifier_count);
            var usable = modifier_count == 0;
            if (modifier_count > 0) {
                const modifiers = try allocator.alloc(u64, @intCast(modifier_count));
                defer allocator.free(modifiers);
                const external = try allocator.alloc(u32, @intCast(modifier_count));
                defer allocator.free(external);
                _ = query_modifiers.?(self.display, format, modifier_count, modifiers.ptr, external.ptr, &modifier_count);
                for (modifiers[0..@intCast(modifier_count)], external[0..@intCast(modifier_count)]) |modifier, external_only| {
                    // External-only layouts cannot be sampled as GL_TEXTURE_2D.
                    if (external_only == 0) {
                        usable = true;
                        try list.append(allocator, .{ .format = @bitCast(format), .modifier = modifier });
                    }
                }
            }
            if (usable) try list.append(allocator, .{ .format = @bitCast(format), .modifier = modifier_invalid });
        }
        return list.toOwnedSlice(allocator);
    }

    fn hasExtension(self: *Renderer, extension: []const u8) bool {
        const list = std.mem.span(eglQueryString(self.display, egl.extensions) orelse return false);
        var names = std.mem.tokenizeScalar(u8, list, ' ');
        while (names.next()) |candidate| if (std.mem.eql(u8, candidate, extension)) return true;
        return false;
    }

    /// Imports a client's GPU buffer; null when the driver rejects it.
    pub fn importDmabuf(self: *Renderer, width: u32, height: u32, format: u32, planes: []const Plane) EGLImage {
        var attributes: [6 + 4 * 10 + 1]isize = undefined;
        var count: usize = 0;
        for ([_]isize{ egl.width, @intCast(width), egl.height, @intCast(height), egl.linux_drm_fourcc, @intCast(format) }) |value| {
            attributes[count] = value;
            count += 1;
        }
        for (planes, 0..) |plane, index| {
            const names = egl.plane_attributes[index];
            var values = [_]isize{ names[0], plane.fd, names[1], @intCast(plane.offset), names[2], @intCast(plane.stride) };
            for (values) |value| {
                attributes[count] = value;
                count += 1;
            }
            if (plane.modifier != modifier_invalid) {
                values = .{ names[3], @intCast(plane.modifier & 0xffffffff), names[4], @intCast(plane.modifier >> 32), 0, 0 };
                for (values[0..4]) |value| {
                    attributes[count] = value;
                    count += 1;
                }
            }
        }
        attributes[count] = egl.none;
        return eglCreateImage(self.display, null, egl.linux_dma_buf, null, &attributes);
    }

    pub fn destroyImage(self: *Renderer, image: EGLImage) void {
        _ = eglDestroyImage(self.display, image);
    }

    /// Makes `texture` sample the client's buffer directly, without a copy.
    pub fn bindImage(self: *Renderer, texture: u32, image: EGLImage) void {
        const target = self.image_target orelse return;
        glBindTexture(gl.texture_2d, texture);
        target(gl.texture_2d, image);
    }

    /// Reads a texture back as premultiplied ARGB, for captures and previews.
    pub fn readTexture(self: *Renderer, texture: u32, width: u32, height: u32, out: []u32) bool {
        var framebuffer: u32 = 0;
        glGenFramebuffers(1, @ptrCast(&framebuffer));
        defer glDeleteFramebuffers(1, @ptrCast(&framebuffer));
        glBindFramebuffer(gl.framebuffer, framebuffer);
        // Drawing continues into the window surface afterwards.
        defer {
            glBindFramebuffer(gl.framebuffer, 0);
            glViewport(0, 0, @intFromFloat(self.target_size[0]), @intFromFloat(self.target_size[1]));
        }
        glFramebufferTexture2D(gl.framebuffer, gl.color_attachment0, gl.texture_2d, texture, 0);
        if (glCheckFramebufferStatus(gl.framebuffer) != gl.framebuffer_complete) return false;
        glPixelStorei(gl.pack_alignment, 4);
        glReadPixels(0, 0, @intCast(width), @intCast(height), gl.rgba, gl.unsigned_byte, out.ptr);
        // RGBA bytes to ARGB words.
        for (out[0 .. @as(usize, width) * height]) |*pixel| {
            const value = pixel.*;
            pixel.* = (value & 0xff00ff00) | ((value & 0xff) << 16) | ((value >> 16) & 0xff);
        }
        return true;
    }

    /// Makes the GPU wait for a client's fence (a sync_file, taken over)
    /// before the commands that follow, such as sampling its buffer.
    pub fn waitFence(self: *Renderer, fd: i32) bool {
        if (self.dup_fence == null) {
            _ = std.c.close(fd);
            return false;
        }
        const attributes = [_]isize{ egl.sync_native_fence_fd, fd, egl.none };
        const sync = eglCreateSync(self.display, egl.sync_native_fence, &attributes);
        if (sync == null) {
            _ = std.c.close(fd);
            return false;
        }
        defer _ = eglDestroySync(self.display, sync);
        return eglWaitSync(self.display, sync, 0) != 0;
    }

    /// A sync_file that signals when the GPU finished the frame's commands, or -1.
    pub fn frameFence(self: *Renderer) i32 {
        const dup = self.dup_fence orelse return -1;
        const sync = eglCreateSync(self.display, egl.sync_native_fence, null);
        if (sync == null) return -1;
        defer _ = eglDestroySync(self.display, sync);
        glFlush();
        return dup(self.display, sync);
    }

    /// Finishes the frame; returns the buffer to scan out, locked until released.
    pub fn finish(self: *Renderer, target: *Target) ?*GbmBo {
        // The fence of everything sampled so far, for release points.
        const fence = self.frameFence();
        if (fence >= 0) {
            if (self.last_fence >= 0) _ = std.c.close(self.last_fence);
            self.last_fence = fence;
        }
        if (eglSwapBuffers(self.display, target.surface) == 0) return null;
        return gbm_surface_lock_front_buffer(target.gbm_surface);
    }

    pub fn createTarget(self: *Renderer, width: u32, height: u32) Error!*Target {
        const surface = gbm_surface_create(self.gbm, width, height, gbm_format_xrgb8888, gbm_bo_use_scanout | gbm_bo_use_rendering) orelse return error.NoSurface;
        errdefer gbm_surface_destroy(surface);
        const egl_surface = eglCreatePlatformWindowSurface(self.display, self.config, surface, null);
        if (egl_surface == null) return error.NoSurface;
        errdefer _ = eglDestroySurface(self.display, egl_surface);
        const target = try self.allocator.create(Target);
        target.* = .{ .renderer = self, .gbm_surface = surface, .surface = egl_surface, .width = width, .height = height };
        return target;
    }
};

/// A scanout target: a GBM surface rendered through an EGL window surface.
pub const Target = struct {
    renderer: *Renderer,
    gbm_surface: *GbmSurface,
    surface: EGLSurface,
    width: u32,
    height: u32,
    /// The buffer on screen, and the one waiting for its flip.
    front: ?*GbmBo = null,
    pending: ?*GbmBo = null,

    /// The pending buffer reached the screen; the old front can be drawn again.
    pub fn flipped(self: *Target) void {
        if (self.front) |bo| gbm_surface_release_buffer(self.gbm_surface, bo);
        self.front = self.pending;
        self.pending = null;
    }

    /// A buffer that could not be shown goes back to the surface.
    pub fn discard(self: *Target, bo: *GbmBo) void {
        gbm_surface_release_buffer(self.gbm_surface, bo);
    }

    pub fn destroy(self: *Target) void {
        const renderer = self.renderer;
        _ = eglMakeCurrent(renderer.display, null, null, renderer.context);
        if (self.pending) |bo| gbm_surface_release_buffer(self.gbm_surface, bo);
        if (self.front) |bo| gbm_surface_release_buffer(self.gbm_surface, bo);
        _ = eglDestroySurface(renderer.display, self.surface);
        gbm_surface_destroy(self.gbm_surface);
        renderer.allocator.destroy(self);
    }
};

test "EGL, GLES and GBM constants match their headers" {
    const c = @import("gl-reference");
    try std.testing.expectEqual(@as(u32, c.GBM_FORMAT_XRGB8888), gbm_format_xrgb8888);
    try std.testing.expectEqual(@as(u32, c.GBM_BO_USE_SCANOUT), gbm_bo_use_scanout);
    try std.testing.expectEqual(@as(u32, c.GBM_BO_USE_RENDERING), gbm_bo_use_rendering);
    try std.testing.expectEqual(@as(u32, c.EGL_PLATFORM_GBM_KHR), egl.platform_gbm);
    try std.testing.expectEqual(@as(u32, c.EGL_OPENGL_ES_API), egl.opengl_es_api);
    try std.testing.expectEqual(@as(i32, c.EGL_NATIVE_VISUAL_ID), egl.native_visual_id);
    try std.testing.expectEqual(@as(i32, c.EGL_CONTEXT_CLIENT_VERSION), egl.context_client_version);
    try std.testing.expectEqual(@as(u32, c.EGL_LINUX_DMA_BUF_EXT), egl.linux_dma_buf);
    try std.testing.expectEqual(@as(u32, c.EGL_SYNC_NATIVE_FENCE_ANDROID), egl.sync_native_fence);
    try std.testing.expectEqual(@as(isize, c.EGL_SYNC_NATIVE_FENCE_FD_ANDROID), egl.sync_native_fence_fd);
    try std.testing.expectEqual(@as(i32, c.EGL_BUFFER_AGE_EXT), egl.buffer_age);
    try std.testing.expectEqual(@as(i32, c.EGL_LINUX_DRM_FOURCC_EXT), egl.linux_drm_fourcc);
    try std.testing.expectEqual(@as(i32, c.EGL_DMA_BUF_PLANE0_FD_EXT), egl.plane_attributes[0][0]);
    try std.testing.expectEqual(@as(i32, c.EGL_DMA_BUF_PLANE1_PITCH_EXT), egl.plane_attributes[1][2]);
    try std.testing.expectEqual(@as(i32, c.EGL_DMA_BUF_PLANE3_FD_EXT), egl.plane_attributes[3][0]);
    try std.testing.expectEqual(@as(i32, c.EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT), egl.plane_attributes[0][3]);
    try std.testing.expectEqual(@as(i32, c.EGL_DMA_BUF_PLANE3_MODIFIER_HI_EXT), egl.plane_attributes[3][4]);
    try std.testing.expectEqual(@as(u32, c.GL_BGRA_EXT), gl.bgra_ext);
    try std.testing.expectEqual(@as(u32, c.GL_TEXTURE_2D), gl.texture_2d);
    try std.testing.expectEqual(@as(u32, c.GL_ONE_MINUS_SRC_ALPHA), gl.one_minus_src_alpha);
    try std.testing.expectEqual(@as(u32, c.GL_SCISSOR_TEST), gl.scissor_test);
    try std.testing.expectEqual(@as(u32, c.GL_UNPACK_ALIGNMENT), gl.unpack_alignment);
    try std.testing.expectEqual(@as(i32, c.GL_CLAMP_TO_EDGE), gl.clamp_to_edge);
    try std.testing.expectEqual(@as(u32, c.GL_FRAMEBUFFER), gl.framebuffer);
    try std.testing.expectEqual(@as(u32, c.GL_COLOR_ATTACHMENT0), gl.color_attachment0);
    try std.testing.expectEqual(@as(u32, c.GL_FRAMEBUFFER_COMPLETE), gl.framebuffer_complete);
    try std.testing.expectEqual(@as(u32, c.GL_PACK_ALIGNMENT), gl.pack_alignment);
    // DRM_FORMAT_MOD_INVALID is fourcc_mod_code(NONE, DRM_FORMAT_RESERVED).
    try std.testing.expectEqual(@as(u64, c.DRM_FORMAT_RESERVED), modifier_invalid);
}

test "integration: GLES draws into scanout buffers on every GPU" {
    if (!@import("options").integration_tests) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tested: usize = 0;
    var name_buffer: [32]u8 = undefined;
    for (128..136) |minor| {
        const path = std.fmt.bufPrintSentinel(&name_buffer, "/dev/dri/renderD{d}", .{minor}, 0) catch unreachable;
        const fd = std.c.open(path, .{ .ACCMODE = .RDWR, .CLOEXEC = true });
        if (fd < 0) continue;
        defer _ = std.c.close(fd);
        const renderer = Renderer.init(a, fd) catch |err| {
            std.debug.print("{s}: no renderer ({s})\n", .{ path, @errorName(err) });
            continue;
        };
        defer renderer.deinit();
        const target = try renderer.createTarget(256, 128);
        defer target.destroy();
        try std.testing.expect(renderer.begin(target, 0xff336699, null, 0));
        const pixels: [4]u32 = @splat(0xffff0000);
        renderer.drawPixels(&pixels, 2, 2, .{ .x = 10, .y = 10, .width = 50, .height = 50 }, null, 1);
        // Explicit sync: a frame fence, and the GPU waiting on one.
        const fence = renderer.frameFence();
        std.debug.print("{s}: native fences {}, frame fence {d}\n", .{ path, renderer.dup_fence != null, fence });
        if (renderer.dup_fence != null) {
            try std.testing.expect(fence >= 0);
            try std.testing.expect(renderer.waitFence(fence));
        }
        const bo = renderer.finish(target) orelse return error.NoBuffer;
        defer target.discard(bo);
        try std.testing.expectEqual(@as(u32, 256), gbm_bo_get_width(bo));
        try std.testing.expectEqual(gbm_format_xrgb8888, gbm_bo_get_format(bo));
        const formats = try renderer.dmabufFormats(a);
        defer a.free(formats);
        std.debug.print("{s}: {s}, layout {x} in {d} planes, {d} client formats, buffer age {}\n", .{ path, renderer.name(), gbm_bo_get_modifier(bo), gbm_bo_get_plane_count(bo), formats.len, renderer.buffer_age });
        try std.testing.expect(formats.len > 0);
        tested += 1;
    }
    if (tested == 0) return error.SkipZigTest;
}
