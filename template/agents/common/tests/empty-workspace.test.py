"""An unconfigured workspace builds without external company destinations."""
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
# A team's checkout may configure its manifests. Check fresh-install behavior in
# isolation instead of requiring every installed workspace to stay unconfigured.
with tempfile.TemporaryDirectory(prefix="empty-workspace-") as raw:
    root = Path(raw)
    shutil.copytree(ROOT / "agents", root / "agents")
    shutil.copy2(ROOT / "ops", root / "ops")
    workspace = json.loads((ROOT / "workspace.json").read_text())
    workspace["customSkills"] = {}
    (root / "workspace.json").write_text(json.dumps(workspace))
    (root / "repos.json").write_text('{"always": [], "repos": {}}')
    (root / "notion.json").write_text('{"roots": {}}')
    result = subprocess.run(["./ops", "check", "--scratch"], cwd=root, capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "temporary directory" in result.stdout
print("empty workspace: pass")
