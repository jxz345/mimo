"""System uptime matching Swift DispatchTime, including on Apple's Python 3.9.

Python 3.9 on macOS reports process-relative time.monotonic(), so it cannot be
subtracted from another process's timing records. Use the kernel clock directly.
"""
import ctypes

class Timebase(ctypes.Structure):
    _fields_ = [('numer', ctypes.c_uint32), ('denom', ctypes.c_uint32)]

_system = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
_system.mach_absolute_time.argtypes = []
_system.mach_absolute_time.restype = ctypes.c_uint64
_system.mach_timebase_info.argtypes = [ctypes.POINTER(Timebase)]
_system.mach_timebase_info.restype = ctypes.c_int
_timebase = Timebase()
assert _system.mach_timebase_info(ctypes.byref(_timebase)) == 0 and _timebase.denom

def uptime_ms():
    return _system.mach_absolute_time() * _timebase.numer // (_timebase.denom * 1_000_000)
