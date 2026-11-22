# flatscreen_vr.py
# Mouse-look, WASD walking, head-locked hands and test buttons for the
# VR-Emulator-Driver (ar-zadeh/VR-Emulator-Driver).
#
# Requires:  pip install openvr numpy scipy
#
# How it works
#   * The driver takes rotation/position CHANGES from C:\actions\*_changes.txt
#     ("a b c", space separated) and resets the file to "0 0 0" once applied.
#   * Which rotation slot turns which way differs between driver builds, so at
#     startup this script nudges the headset, reads its real orientation back
#     from SteamVR (openvr), and works out the driver's rotation convention.
#     Result is cached in C:\actions\.axis_model.json; F9 re-runs it.
#   * It keeps comparing the real pose with where you should be and corrects
#     any drift or leftover tilt automatically.
#   * The driver reads controller buttons straight from the keyboard and uses
#     almost every letter. This script blocks your physical W/A/S/D/M keys from
#     reaching it (while the mouse is captured), so walking doesn't press buttons,
#     and presses the driver's keys for you from the test keys below.

import ctypes
import json
import math
import os
import threading
import time
import warnings
from ctypes import wintypes
from itertools import permutations, product

import sys
import traceback

def _pause_and_exit(msg):
    print(msg)
    input("\nPress Enter to close...")
    sys.exit(1)

try:
    import numpy as np
    from scipy.spatial.transform import Rotation
except ImportError as e:
    _pause_and_exit(f"Missing package: {e.name}\n\nInstall the requirements with this exact Python:\n"
                    f'  "{sys.executable}" -m pip install openvr numpy scipy')

warnings.filterwarnings("ignore", message=".*Gimbal lock.*")

# ---------------- Config ----------------
PLAYER_HEIGHT = 1.75        # meters, eye height
JUMP_HEIGHT = 0.45          # meters your head rises at the top of a jump (Space)
GRAVITY = 9.81              # m/s^2
WALK_SPEED = 1.4            # m/s
SPRINT_MULT = 2.0           # hold Left Shift
MOUSE_SENSITIVITY = 0.12    # degrees per pixel
ARROW_LOOK_SPEED = 90.0     # deg/s, arrow-key look while mouse is released
PITCH_LIMIT_DEG = 85.0
UPDATE_HZ = 90

# Hands relative to your eyes, meters (x = right, y = up, z = back). They follow your view.
LEFT_HAND_OFFSET = (-0.22, -0.30, -0.40)
RIGHT_HAND_OFFSET = (0.22, -0.30, -0.40)

ACTIONS_DIR = r"C:\actions"
MODEL_FILE = os.path.join(ACTIONS_DIR, ".axis_model.json")
DEVICES = {
    "head":  ("headset_position_changes.txt", "headset_rotation_changes.txt"),
    "left":  ("controller1_position_changes.txt", "controller1_rotation_changes.txt"),
    "right": ("controller2_position_changes.txt", "controller2_rotation_changes.txt"),
}

VK_LBUTTON, VK_RBUTTON = 0x01, 0x02
VK_LSHIFT, VK_HOME, VK_F8, VK_F9 = 0xA0, 0x24, 0x77, 0x78
VK_SPACE = 0x20
VK_LEFT, VK_UP, VK_RIGHT, VK_DOWN = 0x25, 0x26, 0x27, 0x28
K_FWD, K_BACK, K_LEFT, K_RIGHT = ord("W"), ord("S"), ord("A"), ord("D")

# Test buttons: (name, keys you press, driver keys to hold down).
# Driver layout: left hand grip=E trigger=X(+S click) menu=W; right hand grip=K trigger=4(+1 click) menu=J.
BUTTONS = [
    ("left grip",     [ord("5"), VK_LBUTTON],  [ord("E")]),
    ("left trigger",  [ord("6")],              [ord("X"), ord("S")]),
    ("right grip",    [ord("7"), VK_RBUTTON],  [ord("K")]),
    ("right trigger", [ord("8")],              [ord("4"), ord("1")]),
    ("menu",          [ord("M")],              [ord("W")]),
]
# Physical keys kept away from the driver (and the game) while the mouse is captured.
BLOCKED_KEYS = {K_FWD, K_BACK, K_LEFT, K_RIGHT, ord("M"), VK_SPACE}


# ======================= Rotation model (driver convention) =======================
# The driver turns its three accumulated slot angles into an orientation as a product
# of three single-axis rotations. We don't know which slot is which axis, the sign, or
# the multiplication order, so we try every combination against measurements.

def all_models():
    for axes in permutations("XYZ"):              # multiplication order of axes
        for slots in permutations(range(3)):      # which slot drives each factor
            for signs in product((1, -1), repeat=3):
                yield {"axes": "".join(axes), "slots": list(slots), "signs": list(signs)}

def model_compose(m, s):
    ang = [m["signs"][i] * s[m["slots"][i]] for i in range(3)]
    return Rotation.from_euler(m["axes"], ang, degrees=True)

def model_decompose(m, rot):
    ang = rot.as_euler(m["axes"], degrees=True)
    s = [0.0, 0.0, 0.0]
    for i in range(3):
        s[m["slots"][i]] = m["signs"][i] * ang[i]
    return s

def angle_between(r1, r2):
    return math.degrees((r1.inv() * r2).magnitude())

def fit_model(r0, probes):
    """r0: rotation before probing; probes: list of (cumulative slot delta, measured rotation)."""
    best, best_err = None, 1e9
    for m in all_models():
        s0 = model_decompose(m, r0)
        err = 0.0
        for d, r in probes:
            err += angle_between(model_compose(m, [a + b for a, b in zip(s0, d)]), r)
            if err > best_err:
                break
        if err < best_err:
            best, best_err = m, err
    return best, best_err / max(1, len(probes))

def wrap180(a):
    return (a + 180.0) % 360.0 - 180.0


# ======================= Everything below needs Windows + SteamVR =======================

def main():
    try:
        import openvr
    except ImportError:
        _pause_and_exit("Missing package: openvr\n\nInstall the requirements with this exact Python:\n"
                        f'  "{sys.executable}" -m pip install openvr numpy scipy')

    user32 = ctypes.windll.user32
    user32.SetProcessDPIAware()
    ctypes.windll.winmm.timeBeginPeriod(1)

    class POINT(ctypes.Structure):
        _fields_ = [("x", wintypes.LONG), ("y", wintypes.LONG)]

    def get_cursor_pos():
        pt = POINT()
        user32.GetCursorPos(ctypes.byref(pt))
        return pt.x, pt.y

    def async_down(vk):
        return (user32.GetAsyncKeyState(vk) & 0x8000) != 0

    def press_key(vk, down):
        user32.keybd_event(vk, user32.MapVirtualKeyW(vk, 0), 0 if down else 0x0002, 0)

    # ---------- Low-level keyboard hook: track and swallow BLOCKED_KEYS ----------
    LRESULT = ctypes.c_ssize_t
    HOOKPROC = ctypes.WINFUNCTYPE(LRESULT, ctypes.c_int, wintypes.WPARAM, wintypes.LPARAM)

    class KBDLLHOOKSTRUCT(ctypes.Structure):
        _fields_ = [("vkCode", wintypes.DWORD), ("scanCode", wintypes.DWORD),
                    ("flags", wintypes.DWORD), ("time", wintypes.DWORD),
                    ("dwExtraInfo", ctypes.c_size_t)]

    user32.SetWindowsHookExW.argtypes = [ctypes.c_int, HOOKPROC, wintypes.HINSTANCE, wintypes.DWORD]
    user32.SetWindowsHookExW.restype = wintypes.HHOOK
    user32.CallNextHookEx.argtypes = [wintypes.HHOOK, ctypes.c_int, wintypes.WPARAM, wintypes.LPARAM]
    user32.CallNextHookEx.restype = LRESULT

    physical = {vk: False for vk in BLOCKED_KEYS}
    hook_state = {"blocking": True}

    def hook_proc(n_code, w_param, l_param):
        if n_code == 0:
            kb = ctypes.cast(l_param, ctypes.POINTER(KBDLLHOOKSTRUCT)).contents
            injected = kb.flags & 0x10
            if kb.vkCode in physical and not injected:
                physical[kb.vkCode] = w_param in (0x100, 0x104)   # WM_KEYDOWN / WM_SYSKEYDOWN
                if hook_state["blocking"]:
                    return 1                                     # swallow: nobody else sees it
        return user32.CallNextHookEx(None, n_code, w_param, l_param)

    hook_cb = HOOKPROC(hook_proc)   # keep a reference so it isn't garbage-collected

    def hook_thread():
        user32.SetWindowsHookExW(13, hook_cb, None, 0)          # WH_KEYBOARD_LL
        msg = wintypes.MSG()
        while user32.GetMessageW(ctypes.byref(msg), None, 0, 0) != 0:
            pass

    threading.Thread(target=hook_thread, daemon=True).start()

    def key_down(vk):
        return physical[vk] if vk in physical else async_down(vk)

    # ---------- Driver files ----------
    def read_triplet(path):
        try:
            with open(path) as f:
                parts = f.read().replace(",", " ").split()
        except FileNotFoundError:
            return None
        except OSError:
            return "busy"
        if len(parts) < 3:
            return "busy"
        try:
            return [float(p) for p in parts[:3]]
        except ValueError:
            return "busy"

    def consumed(path):
        cur = read_triplet(path)
        return cur is None or (cur != "busy" and all(abs(v) < 1e-9 for v in cur))

    def try_send(path, delta):
        if all(abs(v) < 1e-6 for v in delta):
            return True
        if not consumed(path):
            return False
        tmp = path + ".tmp"
        try:
            with open(tmp, "w") as f:
                f.write(f"{delta[0]:.6f} {delta[1]:.6f} {delta[2]:.6f}")
            os.replace(tmp, path)
            return True
        except OSError:
            return False

    # ---------- SteamVR readback ----------
    print("Waiting for SteamVR...")
    while True:
        try:
            openvr.init(openvr.VRApplication_Background)
            break
        except openvr.OpenVRError:
            time.sleep(1)
    vrsys = openvr.VRSystem()

    def device_indices():
        idx = {"head": openvr.k_unTrackedDeviceIndex_Hmd}
        for i in range(openvr.k_unMaxTrackedDeviceCount):
            if vrsys.getTrackedDeviceClass(i) == openvr.TrackedDeviceClass_Controller:
                role = vrsys.getControllerRoleForTrackedDeviceIndex(i)
                if role == openvr.TrackedControllerRole_LeftHand:
                    idx["left"] = i
                elif role == openvr.TrackedControllerRole_RightHand:
                    idx["right"] = i
        return idx

    def read_poses(idx):
        poses = vrsys.getDeviceToAbsoluteTrackingPose(
            openvr.TrackingUniverseRawAndUncalibrated, 0, openvr.k_unMaxTrackedDeviceCount)
        out = {}
        for name, i in idx.items():
            p = poses[i]
            if p.bPoseIsValid:
                m = p.mDeviceToAbsoluteTracking.m
                mat = np.array([[m[r][c] for c in range(3)] for r in range(3)])
                out[name] = ([m[0][3], m[1][3], m[2][3]], Rotation.from_matrix(mat))
        return out

    idx = device_indices()
    print("Tracked devices:", ", ".join(f"{k}=#{v}" for k, v in idx.items()))
    if "left" not in idx or "right" not in idx:
        print("Warning: SteamVR doesn't report both hands yet; hands will start following once they appear.")

    devices = {n: {"pos_file": os.path.join(ACTIONS_DIR, f[0]),
                   "rot_file": os.path.join(ACTIONS_DIR, f[1]),
                   "sent_pos": None, "sent_s": None, "last_send": 0.0}
               for n, f in DEVICES.items()}

    # ---------- Calibration ----------
    def send_blocking(path, delta, timeout=2.0):
        t0 = time.time()
        while not try_send(path, delta):
            if time.time() - t0 > timeout:
                return False
            time.sleep(0.005)
        t0 = time.time()
        while not consumed(path) and time.time() - t0 < timeout:
            time.sleep(0.005)
        time.sleep(0.12)   # let SteamVR publish the new pose
        return True

    def calibrate():
        print("Calibrating rotation axes (the view will twitch for ~2 seconds)...")
        head = devices["head"]
        r0 = read_poses(idx)["head"][1]
        steps = [(20, 0, 0), (0, 25, 0), (0, 0, 30), (15, -20, 25), (-10, 35, -15)]
        cum, probes = [0.0, 0.0, 0.0], []
        for st in steps:
            if not send_blocking(head["rot_file"], st):
                raise RuntimeError("Driver isn't consuming the rotation file - is the emulator driver loaded?")
            cum = [a + b for a, b in zip(cum, st)]
            probes.append((list(cum), read_poses(idx)["head"][1]))
        send_blocking(head["rot_file"], [-c for c in cum])       # undo the probes
        m, err = fit_model(r0, probes)
        print(f"  Driver rotation = {m['axes']} axes driven by slots {m['slots']} with signs {m['signs']} "
              f"(fit error {err:.2f} deg)")
        if err > 3.0:
            print("  WARNING: poor fit - rotation may still be off. Press F9 to retry.")
        try:
            with open(MODEL_FILE, "w") as f:
                json.dump(m, f)
        except OSError:
            pass
        return m

    model = None
    try:
        with open(MODEL_FILE) as f:
            model = json.load(f)
        print("Using cached rotation calibration (F9 to redo).")
    except Exception:
        pass
    if model is None:
        model = calibrate()

    # ---------- Starting view from wherever the headset actually is ----------
    head_pos, head_rot = read_poses(idx)["head"]
    fwd = head_rot.apply([0, 0, -1])
    view = {"x": head_pos[0], "z": head_pos[2],
            "yaw": math.degrees(math.atan2(-fwd[0], -fwd[2])), "pitch": 0.0}

    view["jump_y"], view["jump_v"] = 0.0, 0.0   # height above the floor from jumping, and its speed
    print("\nMove: WASD (Left Shift = sprint, Space = jump)   Look: mouse")
    print("Left hand:  5 = grip, 6 = trigger   (left mouse also = grip)")
    print("Right hand: 7 = grip, 8 = trigger   (right mouse also = grip)")
    print("M = menu button   Home = recenter   F8 = capture/release mouse   F9 = recalibrate   Ctrl+C = quit")

    mouse_captured = True
    prev = {"f8": False, "f9": False, "home": False}
    held = set()
    center_x = user32.GetSystemMetrics(0) // 2
    center_y = user32.GetSystemMetrics(1) // 2
    user32.SetCursorPos(center_x, center_y)
    last = time.perf_counter()
    last_idx_check = last

    def edge(name, vk):
        now_down = async_down(vk)
        fired = now_down and not prev[name]
        prev[name] = now_down
        return fired

    try:
        while True:
            now = time.perf_counter()
            dt = min(now - last, 0.1)
            last = now

            if now - last_idx_check > 2.0 and ("left" not in idx or "right" not in idx):
                idx = device_indices()
                last_idx_check = now

            if edge("f8", VK_F8):
                mouse_captured = not mouse_captured
                hook_state["blocking"] = mouse_captured
                print("Mouse captured" if mouse_captured else "Mouse released (WASD/M pass through to other apps)")
                if mouse_captured:
                    user32.SetCursorPos(center_x, center_y)

            if edge("f9", VK_F9):
                model = calibrate()
                for d in devices.values():
                    d["sent_s"] = None

            # --- Buttons ---
            want = set()
            for _, inputs, keys in BUTTONS:
                for i in inputs:
                    if i in (VK_LBUTTON, VK_RBUTTON) and not mouse_captured:
                        continue
                    if key_down(i):
                        want.update(keys)
            for k in want - held:
                press_key(k, True)
            for k in held - want:
                press_key(k, False)
            held = want

            # --- Look ---
            if mouse_captured:
                x, y = get_cursor_pos()
                dx, dy = x - center_x, y - center_y
                if dx or dy:
                    view["yaw"] -= dx * MOUSE_SENSITIVITY
                    view["pitch"] -= dy * MOUSE_SENSITIVITY
                    user32.SetCursorPos(center_x, center_y)
            else:
                step = ARROW_LOOK_SPEED * dt
                if async_down(VK_LEFT):  view["yaw"] += step
                if async_down(VK_RIGHT): view["yaw"] -= step
                if async_down(VK_UP):    view["pitch"] += step
                if async_down(VK_DOWN):  view["pitch"] -= step
            view["pitch"] = max(-PITCH_LIMIT_DEG, min(PITCH_LIMIT_DEG, view["pitch"]))
            view["yaw"] = wrap180(view["yaw"])

            # --- Walk ---
            fwd_in = int(key_down(K_FWD)) - int(key_down(K_BACK))
            side_in = int(key_down(K_RIGHT)) - int(key_down(K_LEFT))
            if fwd_in or side_in:
                speed = WALK_SPEED * (SPRINT_MULT if async_down(VK_LSHIFT) else 1.0)
                dist = speed * dt / math.hypot(fwd_in, side_in)
                ry = math.radians(view["yaw"])
                view["x"] += (fwd_in * -math.sin(ry) + side_in * math.cos(ry)) * dist
                view["z"] += (fwd_in * -math.cos(ry) + side_in * -math.sin(ry)) * dist

            # --- Jump: launch with the speed that peaks at JUMP_HEIGHT, then fall back down ---
            grounded = view["jump_y"] <= 0.0
            if grounded and key_down(VK_SPACE):
                view["jump_v"] = math.sqrt(2.0 * GRAVITY * JUMP_HEIGHT)
                grounded = False
            if not grounded:
                view["jump_v"] -= GRAVITY * dt
                view["jump_y"] += view["jump_v"] * dt
                if view["jump_y"] <= 0.0:
                    view["jump_y"], view["jump_v"] = 0.0, 0.0

            if edge("home", VK_HOME):
                view.update({"x": 0.0, "z": 0.0, "yaw": 0.0, "pitch": 0.0})
                print("Recentered.")

            # --- Targets ---
            look = Rotation.from_euler("YX", [view["yaw"], view["pitch"]], degrees=True)
            eye = np.array([view["x"], PLAYER_HEIGHT + view["jump_y"], view["z"]])
            targets = {"head": (eye, look)}
            for name, off in (("left", LEFT_HAND_OFFSET), ("right", RIGHT_HAND_OFFSET)):
                targets[name] = (eye + look.apply(off), look)

            # --- Drive each device toward its target ---
            actual = read_poses(idx)
            for name, d in devices.items():
                if name not in actual:
                    continue
                # Re-sync our idea of the driver's state from the real pose whenever
                # nothing is in flight, so lost writes or leftovers get corrected.
                idle = now - d["last_send"] > 0.15 and consumed(d["pos_file"]) and consumed(d["rot_file"])
                if d["sent_s"] is None or idle:
                    d["sent_pos"] = list(actual[name][0])
                    d["sent_s"] = model_decompose(model, actual[name][1])
                tpos, trot = targets[name]
                dp = [float(t - s) for t, s in zip(tpos, d["sent_pos"])]
                if max(abs(v) for v in dp) > 1e-4 and try_send(d["pos_file"], dp):
                    d["sent_pos"] = [float(v) for v in tpos]
                    d["last_send"] = now
                ts = model_decompose(model, trot)
                ds = [wrap180(t - s) for t, s in zip(ts, d["sent_s"])]
                if max(abs(v) for v in ds) > 0.01 and try_send(d["rot_file"], ds):
                    d["sent_s"] = [s + v for s, v in zip(d["sent_s"], ds)]
                    d["last_send"] = now

            time.sleep(max(0.0, 1.0 / UPDATE_HZ - (time.perf_counter() - now)))
    except KeyboardInterrupt:
        print("Stopped.")
    finally:
        for k in held:
            press_key(k, False)
        openvr.shutdown()
        ctypes.windll.winmm.timeEndPeriod(1)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception:
        traceback.print_exc()
        _pause_and_exit("\nThe script crashed - copy the error above and send it over.")
