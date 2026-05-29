"""
Root conftest for pytest.

Ensures the project root is on sys.path so that `import core...` resolves
regardless of the directory pytest is invoked from. Running
`python3 -m pytest tests/` from the project root already puts CWD on sys.path,
but this guard makes the suite robust to other invocation styles.
"""

import os
import sys

PROJECT_ROOT = os.path.dirname(os.path.abspath(__file__))

if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)
