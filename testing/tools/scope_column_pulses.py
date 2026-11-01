"""Extract scope column pulses without inventing a final falling-pulse end."""

import numpy as np
from scipy.ndimage import binary_closing


def extract(voltage, dt):
    length = max(1, round(.55e-6 / dt))
    low = binary_closing(voltage < 1.5, structure=np.ones(length))
    edge = np.diff(np.r_[False, low, False].astype(np.int8))
    starts, stops = np.flatnonzero(edge == 1), np.flatnonzero(edge == -1)
    censored = None
    # Closing erodes the boundary and can manufacture an apparent rising edge.
    if (len(starts) and voltage[-1] < 1.5
            and len(voltage)-stops[-1] <= length
            and np.all(voltage[stops[-1]:] < 1.5)):
        censored = dict(start_s=float(starts[-1]*dt), observed_end_s=len(voltage)*dt,
                        observed_width_us=float((len(voltage)-starts[-1])*dt*1e6),
                        reason="原始列信号在记录末端仍为低；结束边沿未被观测")
        starts, stops = starts[:-1], stops[:-1]
    long = np.flatnonzero((stops-starts)*dt > 10e-6)
    if not len(long):
        raise ValueError("未检测到完整列扫描脉冲")
    keep = ((stops-starts)*dt > 1e-6) & (starts >= starts[long[0]])
    return starts[keep], stops[keep], censored
