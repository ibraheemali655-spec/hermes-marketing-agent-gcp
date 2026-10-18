import sys
import types
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path[:0] = [str(ROOT), str(ROOT / "infra" / "vm"), str(ROOT / "infra" / "waker")]


class FakeInstances:
    """Stands in for google.cloud.compute_v1.InstancesClient."""

    def __init__(self):
        self.status = "TERMINATED"
        self.starts = 0

    def get(self, project, zone, instance):
        return types.SimpleNamespace(status=self.status)

    def start(self, project, zone, instance):
        self.starts += 1
        self.status = "RUNNING"
        return types.SimpleNamespace(name="op-1")


# The waker imports google.cloud.compute_v1 at module load; tests never talk to GCP.
compute_v1 = types.ModuleType("google.cloud.compute_v1")
compute_v1.InstancesClient = FakeInstances
google = sys.modules.setdefault("google", types.ModuleType("google"))
cloud = sys.modules.setdefault("google.cloud", types.ModuleType("google.cloud"))
google.cloud = cloud
cloud.compute_v1 = compute_v1
sys.modules["google.cloud.compute_v1"] = compute_v1
