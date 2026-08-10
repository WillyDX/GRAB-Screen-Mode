import time
import ctypes
from ctypes import wintypes

# ---- Config ----
PLAYER_HEIGHT = 1.75  # meters -- your headset's Y position
POS_FILE = r"C:\actions\headset_position_changes.txt"
ROT_FILE = r"C:\actions\headset_rotation_changes.txt"
MOUSE_SENSITIVITY = 0.15   # degrees per pixel of mouse movement
ARROW_SPEED = 1.2          # degrees per frame while an arrow key is held
DEADZONE_PX = 1            # ignore residual jitter smaller than this many pixels
UPDATE_HZ = 90
PITCH_LIMIT_DEG = 89.0

user32 = ctypes.windll.user32

# Tell Windows this process handles its own scaling, so GetCursorPos/SetCursorPos
# use consistent, un-virtualized pixel coordinates. Without this, the two calls
# can disagree by a pixel or two, which reads as constant phantom mouse movement.
user32.SetProcessDPIAware()

class POINT(ctypes.Structure):
    _fields_ = [("x", wintypes.LONG), ("y", wintypes.LONG)]

def get_cursor_pos():
    pt = POINT()
    user32.GetCursorPos(ctypes.byref(pt))
    return pt.x, pt.y

def set_cursor_pos(x, y):
    user32.SetCursorPos(x, y)

def key_down(vk_code):
    # High bit set means the key is currently held down.
    return user32.GetAsyncKeyState(vk_code) & 0x8000 != 0

VK_ESCAPE = 0x1B
VK_LEFT = 0x25
VK_UP = 0x26
VK_RIGHT = 0x27
VK_DOWN = 0x28

SCREEN_W = user32.GetSystemMetrics(0)
SCREEN_H = user32.GetSystemMetrics(1)
CENTER_X, CENTER_Y = SCREEN_W // 2, SCREEN_H // 2

yaw = 0.0
pitch = 0.0
mouse_tracking = True
esc_was_down = False

def write_pose():
    with open(POS_FILE, "w") as f:
        f.write(f"0.0,{PLAYER_HEIGHT},0.0")
    with open(ROT_FILE, "w") as f:
        f.write(f"{yaw:.3f},{pitch:.3f},0.0")

print("Mouse-look running at height", PLAYER_HEIGHT, "m.")
print("Press ESC to toggle between mouse-look and arrow-key look. Ctrl+C to stop.")

set_cursor_pos(CENTER_X, CENTER_Y)
time.sleep(0.05)

try:
    while True:
        # --- ESC toggles mode (edge-triggered so it only fires once per press) ---
        esc_now = key_down(VK_ESCAPE)
        if esc_now and not esc_was_down:
            mouse_tracking = not mouse_tracking
            print("Mouse-look ENABLED" if mouse_tracking else "Arrow-key look ENABLED (mouse ignored)")
            if mouse_tracking:
                set_cursor_pos(CENTER_X, CENTER_Y)  # avoid a jump when re-enabling
        esc_was_down = esc_now

        if mouse_tracking:
            x, y = get_cursor_pos()
            dx = x - CENTER_X
            dy = y - CENTER_Y
            if abs(dx) > DEADZONE_PX or abs(dy) > DEADZONE_PX:
                yaw += dx * MOUSE_SENSITIVITY
                pitch -= dy * MOUSE_SENSITIVITY
                pitch = max(-PITCH_LIMIT_DEG, min(PITCH_LIMIT_DEG, pitch))
                set_cursor_pos(CENTER_X, CENTER_Y)
        else:
            if key_down(VK_LEFT):
                yaw -= ARROW_SPEED
            if key_down(VK_RIGHT):
                yaw += ARROW_SPEED
            if key_down(VK_UP):
                pitch += ARROW_SPEED
            if key_down(VK_DOWN):
                pitch -= ARROW_SPEED
            pitch = max(-PITCH_LIMIT_DEG, min(PITCH_LIMIT_DEG, pitch))

        write_pose()
        time.sleep(1 / UPDATE_HZ)
except KeyboardInterrupt:
    print("Stopped.")