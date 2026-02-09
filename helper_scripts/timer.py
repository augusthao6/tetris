from time import time
from typing import Dict, List, Tuple

class Timer:
    _start_times: Dict[str, float] = {}
    _completed_timings: List[Tuple[str, float]] = []

    @classmethod
    def start_timer(cls, key: str) -> None:
        """Start timing for the given key."""
        cls._start_times[key] = time()
    
    @classmethod
    def end_timer(cls, key: str) -> None:
        """End timing for the given key and record the duration. Implicity sorted by end time."""
        if key not in cls._start_times:
            return
        
        end_time = time()
        duration = end_time - cls._start_times[key]
        cls._completed_timings.append((key, duration))
        del cls._start_times[key]
    
    @classmethod
    def print_timings(cls) -> str:
        if not cls._completed_timings:
            return "No timings recorded."
        
        # Find the longest key length for proper alignment
        max_key_length = max(len(key) for key, _ in cls._completed_timings)

        return "Timing Summary:\n" + "\n".join(
            [f"{key:<{max_key_length}}  |  {duration:>.4f} seconds" for key, duration in cls._completed_timings]
        )
