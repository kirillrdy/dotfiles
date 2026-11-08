{ desktop }:
''
  export XDG_RUNTIME_DIR="$TMPDIR/wayland-runtime"
  mkdir -m 700 -p "$XDG_RUNTIME_DIR"
  # Absolute paths survive tests creating their own private runtime directories.
  export WAYLAND_DISPLAY="$XDG_RUNTIME_DIR/wayland-0" GDK_BACKEND=wayland
  export WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_HEADLESS_OUTPUTS=1
  ${desktop}/bin/desktop-zig compositor-only > "$TMPDIR/compositor.log" 2>&1 &
  fixture_compositor_pid=$!
  trap 'kill "$fixture_compositor_pid" 2>/dev/null || true' EXIT
  for attempt in $(seq 1 100); do
    test -S "$WAYLAND_DISPLAY" && break
    if ! kill -0 "$fixture_compositor_pid" 2>/dev/null; then
      cat "$TMPDIR/compositor.log" >&2
      exit 1
    fi
    sleep 0.05
  done
  test -S "$WAYLAND_DISPLAY"
''
