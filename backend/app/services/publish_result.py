from dataclasses import dataclass


@dataclass
class PublishResult:
    stream_target: str
    attempts: int
    duration_ms: int

