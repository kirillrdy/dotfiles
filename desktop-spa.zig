//! SPA and PipeWire protocol constants, declared explicitly. Tests compare them
//! with the installed PipeWire headers (tests/desktop-libc-abi.zig).
// POD types.
pub const SPA_TYPE_None = 1;
pub const SPA_TYPE_Bool = 2;
pub const SPA_TYPE_Id = 3;
pub const SPA_TYPE_Int = 4;
pub const SPA_TYPE_Long = 5;
pub const SPA_TYPE_Float = 6;
pub const SPA_TYPE_String = 8;
pub const SPA_TYPE_Array = 13;
pub const SPA_TYPE_Struct = 14;
pub const SPA_TYPE_Object = 15;
pub const SPA_TYPE_Fd = 18;
pub const SPA_TYPE_Choice = 19;
pub const SPA_TYPE_OBJECT_Props = 0x40002;
pub const SPA_TYPE_OBJECT_ParamBuffers = 0x40004;
pub const SPA_TYPE_OBJECT_ParamRoute = 0x40009;
pub const SPA_CHOICE_Flags = 4;
// Parameters and their properties.
pub const SPA_PARAM_Props = 2;
pub const SPA_PARAM_Buffers = 5;
pub const SPA_PARAM_Route = 13;
pub const SPA_PARAM_INFO_SERIAL = 1 << 0;
pub const SPA_PARAM_INFO_READ = 1 << 1;
pub const SPA_PROP_volume = 0x10003;
pub const SPA_PROP_mute = 0x10004;
pub const SPA_PROP_channelVolumes = 0x10008;
pub const SPA_PARAM_ROUTE_index = 1;
pub const SPA_PARAM_ROUTE_device = 3;
pub const SPA_PARAM_ROUTE_props = 10;
pub const SPA_PARAM_ROUTE_save = 13;
pub const SPA_PARAM_BUFFERS_dataType = 6;
pub const SPA_DATA_MemFd = 2;
// Objects.
pub const PW_ID_CORE = 0;
pub const PW_ID_ANY = 0xffffffff;
pub const PW_VERSION_CORE = 4;
pub const PW_VERSION_REGISTRY = 3;
pub const PW_VERSION_NODE = 3;
pub const PW_VERSION_DEVICE = 3;
pub const PW_VERSION_METADATA = 3;
pub const PW_TYPE_INTERFACE_Node = "PipeWire:Interface:Node";
pub const PW_TYPE_INTERFACE_Device = "PipeWire:Interface:Device";
pub const PW_TYPE_INTERFACE_Metadata = "PipeWire:Interface:Metadata";
pub const PW_NODE_STATE_RUNNING = 3;
pub const PW_NODE_CHANGE_MASK_STATE = 1 << 2;
pub const PW_NODE_CHANGE_MASK_PROPS = 1 << 3;
pub const PW_NODE_CHANGE_MASK_PARAMS = 1 << 4;
pub const PW_DEVICE_CHANGE_MASK_PROPS = 1 << 0;
pub const PW_DEVICE_CHANGE_MASK_PARAMS = 1 << 1;
// Native protocol opcodes.
pub const PW_CORE_METHOD_HELLO = 1;
pub const PW_CORE_METHOD_SYNC = 2;
pub const PW_CORE_METHOD_PONG = 3;
pub const PW_CORE_METHOD_GET_REGISTRY = 5;
pub const PW_CORE_EVENT_DONE = 1;
pub const PW_CORE_EVENT_PING = 2;
pub const PW_CORE_EVENT_ERROR = 3;
pub const PW_CORE_EVENT_REMOVE_ID = 4;
pub const PW_CLIENT_METHOD_UPDATE_PROPERTIES = 2;
pub const PW_REGISTRY_METHOD_BIND = 1;
pub const PW_REGISTRY_EVENT_GLOBAL = 0;
pub const PW_REGISTRY_EVENT_GLOBAL_REMOVE = 1;
pub const PW_NODE_METHOD_SUBSCRIBE_PARAMS = 1;
pub const PW_NODE_METHOD_ENUM_PARAMS = 2;
pub const PW_NODE_METHOD_SET_PARAM = 3;
pub const PW_NODE_EVENT_INFO = 0;
pub const PW_NODE_EVENT_PARAM = 1;
pub const PW_DEVICE_METHOD_SUBSCRIBE_PARAMS = 1;
pub const PW_DEVICE_METHOD_SET_PARAM = 3;
pub const PW_DEVICE_EVENT_INFO = 0;
pub const PW_DEVICE_EVENT_PARAM = 1;
pub const PW_METADATA_METHOD_SET_PROPERTY = 1;
pub const PW_METADATA_EVENT_PROPERTY = 0;
// Exported nodes: the client-node interface, its media and buffer parameters.
pub const SPA_TYPE_Rectangle = 10;
pub const SPA_TYPE_Fraction = 11;
pub const SPA_TYPE_OBJECT_Format = 0x40003;
pub const SPA_TYPE_OBJECT_ParamIO = 0x40006;
pub const SPA_TYPE_COMMAND_Node = 0x30002;
pub const SPA_PARAM_EnumFormat = 3;
pub const SPA_PARAM_Format = 4;
pub const SPA_PARAM_IO = 7;
pub const SPA_PARAM_PortConfig = 11;
pub const SPA_PARAM_INFO_WRITE = 1 << 2;
pub const SPA_PARAM_INFO_READWRITE = SPA_PARAM_INFO_READ | SPA_PARAM_INFO_WRITE;
pub const SPA_PARAM_IO_id = 1;
pub const SPA_PARAM_IO_size = 2;
pub const SPA_PARAM_BUFFERS_buffers = 1;
pub const SPA_PARAM_BUFFERS_blocks = 2;
pub const SPA_PARAM_BUFFERS_size = 3;
pub const SPA_PARAM_BUFFERS_stride = 4;
pub const SPA_FORMAT_mediaType = 1;
pub const SPA_FORMAT_mediaSubtype = 2;
pub const SPA_FORMAT_AUDIO_format = 0x10001;
pub const SPA_FORMAT_AUDIO_channels = 0x10004;
pub const SPA_FORMAT_AUDIO_position = 0x10005;
pub const SPA_AUDIO_FORMAT_F32P = 518;
pub const SPA_AUDIO_CHANNEL_FL = 3;
pub const SPA_AUDIO_CHANNEL_FR = 4;
pub const SPA_FORMAT_VIDEO_format = 0x20001;
pub const SPA_FORMAT_VIDEO_size = 0x20003;
pub const SPA_FORMAT_VIDEO_framerate = 0x20004;
pub const SPA_MEDIA_TYPE_audio = 1;
pub const SPA_MEDIA_TYPE_video = 2;
pub const SPA_MEDIA_SUBTYPE_raw = 1;
pub const SPA_MEDIA_SUBTYPE_dsp = 2;
pub const SPA_AUDIO_FORMAT_DSP_F32 = 518;
pub const SPA_VIDEO_FORMAT_BGRx = 8;
pub const SPA_VIDEO_FORMAT_xRGB = 9;
pub const SPA_DATA_MemPtr = 1;
pub const SPA_DATA_MemId = 4;
pub const SPA_IO_Buffers = 1;
pub const SPA_IO_Clock = 3;
pub const SPA_IO_Position = 7;
pub const SPA_IO_AsyncBuffers = 10;
pub const SPA_STATUS_NEED_DATA = 1 << 0;
pub const SPA_STATUS_HAVE_DATA = 1 << 1;
pub const SPA_NODE_COMMAND_Suspend = 0;
pub const SPA_NODE_COMMAND_Pause = 1;
pub const SPA_NODE_COMMAND_Start = 2;
pub const SPA_NODE_FLAG_RT = 1 << 0;
pub const SPA_NODE_CHANGE_MASK_FLAGS = 1 << 0;
pub const SPA_NODE_CHANGE_MASK_PROPS = 1 << 1;
pub const SPA_NODE_CHANGE_MASK_PARAMS = 1 << 2;
pub const SPA_PORT_CHANGE_MASK_FLAGS = 1 << 0;
pub const SPA_PORT_CHANGE_MASK_RATE = 1 << 1;
pub const SPA_PORT_CHANGE_MASK_PROPS = 1 << 2;
pub const SPA_PORT_CHANGE_MASK_PARAMS = 1 << 3;
pub const SPA_DIRECTION_OUTPUT = 1;
pub const PW_VERSION_CLIENT_NODE = 6;
pub const PW_TYPE_INTERFACE_ClientNode = "PipeWire:Interface:ClientNode";
pub const PW_CORE_METHOD_CREATE_OBJECT = 6;
pub const PW_CORE_EVENT_BOUND_ID = 5;
pub const PW_CORE_EVENT_ADD_MEM = 6;
pub const PW_CORE_EVENT_REMOVE_MEM = 7;
pub const PW_CORE_EVENT_BOUND_PROPS = 8;
pub const PW_CLIENT_NODE_UPDATE_PARAMS = 1 << 0;
pub const PW_CLIENT_NODE_UPDATE_INFO = 1 << 1;
pub const PW_CLIENT_NODE_PORT_UPDATE_PARAMS = 1 << 0;
pub const PW_CLIENT_NODE_PORT_UPDATE_INFO = 1 << 1;
pub const PW_CLIENT_NODE_METHOD_UPDATE = 2;
pub const PW_CLIENT_NODE_METHOD_PORT_UPDATE = 3;
pub const PW_CLIENT_NODE_METHOD_SET_ACTIVE = 4;
pub const PW_CLIENT_NODE_EVENT_TRANSPORT = 0;
pub const PW_CLIENT_NODE_EVENT_SET_PARAM = 1;
pub const PW_CLIENT_NODE_EVENT_SET_IO = 2;
pub const PW_CLIENT_NODE_EVENT_COMMAND = 4;
pub const PW_CLIENT_NODE_EVENT_PORT_SET_PARAM = 7;
pub const PW_CLIENT_NODE_EVENT_PORT_USE_BUFFERS = 8;
pub const PW_CLIENT_NODE_EVENT_PORT_SET_IO = 9;
pub const PW_CLIENT_NODE_EVENT_SET_ACTIVATION = 10;
pub const PW_CLIENT_NODE_EVENT_PORT_SET_MIX_INFO = 11;
// Shared memory: io areas, buffer chunks and the driver's clock and position.
pub const spa_io_buffers = extern struct { status: i32, buffer_id: u32 };
pub const spa_chunk = extern struct { offset: u32, size: u32, stride: i32, flags: i32 };
pub const spa_fraction = extern struct { num: u32, denom: u32 };
pub const spa_io_clock = extern struct {
    flags: u32,
    id: u32,
    name: [64]u8,
    nsec: u64,
    rate: spa_fraction,
    position: u64,
    duration: u64,
    delay: i64,
    rate_diff: f64,
    next_nsec: u64,
    target_rate: spa_fraction,
    target_duration: u64,
    target_seq: u32,
    cycle: u32,
    xrun: u64,
};
pub const spa_io_position = extern struct {
    clock: spa_io_clock,
    video: [40]u8 align(8),
    offset: i64,
    state: u32,
    n_segments: u32,
    segments: [8 * 184]u8 align(8),
};
// PipeWire's node activation record (src/pipewire/private.h), shared between
// the server and each client. Its first word after `status` holds bitfields.
pub const pw_node_activation_state = extern struct { status: i32, required: i32, pending: i32 };
pub const pw_node_activation = extern struct {
    status: u32,
    bits: u32,
    state: [2]pw_node_activation_state,
    signal_time: u64,
    awake_time: u64,
    finish_time: u64,
    prev_signal_time: u64,
    reposition: [184]u8 align(8),
    segment: [184]u8 align(8),
    segment_owner: [16]u32,
    prev_awake_time: u64,
    prev_finish_time: u64,
    padding: [7]u32,
    client_version: u32,
    server_version: u32,
    active_driver_id: u32,
    driver_id: u32,
    flags: u32,
    position: spa_io_position,
    sync_timeout: u64,
    sync_left: u64,
    cpu_load: [3]f32,
    xrun_count: u32,
    xrun_time: u64,
    xrun_delay: u64,
    max_delay: u64,
    command: u32,
    reposition_owner: u32,
};
