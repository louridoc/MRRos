"""When to re-publish the last scan to subscribers that joined after it was published.

The cloud topic is latched (TRANSIENT_LOCAL), so latched subscribers such as RViz get the last
scan on their own. MoveIt's octomap updater subscribes VOLATILE, so a move_group that starts or
restarts after an upload never sees the scan and plans as if the room were empty, silently (M5a).
The node polls the topic's volatile subscriptions; this decides when to re-publish. rclpy-free so
it's unit-testable.
"""

from collections.abc import Hashable, Iterable


class LateJoinWatcher:
    """Schedules a re-publish `delay_s` after a new volatile subscriber appears.

    The delay lets a fresh move_group get its robot state and TF before the cloud arrives; its
    self-filter needs both. Several joiners in a row push the deadline back (debounce) so they
    get one re-publish together, and `due()` fires once per schedule.
    """

    def __init__(self, delay_s: float) -> None:
        self.delay_s = delay_s
        self._known: set[Hashable] = set()
        self._due_at: float | None = None

    def observe(self, now: float, subscriber_ids: Iterable[Hashable]) -> bool:
        """Records the current volatile subscribers; True if any is new (a re-publish was
        scheduled). Vanished ones are forgotten — a restart shows up as a new ID anyway."""
        current = set(subscriber_ids)
        joined = current - self._known
        self._known = current
        if joined:
            self._due_at = now + self.delay_s
        return bool(joined)

    def due(self, now: float) -> bool:
        if self._due_at is None or now < self._due_at:
            return False
        self._due_at = None
        return True
