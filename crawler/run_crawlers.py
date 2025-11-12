import os
import sys
import threading
import subprocess
from typing import List, Tuple


def stream_output(name: str, proc: subprocess.Popen) -> None:
    try:
        assert proc.stdout is not None
        for line in proc.stdout:
            print(f"[{name}] {line}", end="")
    except Exception as e:
        print(f"[{name}] Output reader error: {e}")


def main() -> int:
    script_dir = os.path.dirname(os.path.abspath(__file__))
    cmds: List[Tuple[str, List[str]]] = [
        ("bunjang", [sys.executable, os.path.join(script_dir, "bunjangCrawler.py")]),
        ("daangn", [sys.executable, os.path.join(script_dir, "daangnCrawler.py")]),
        ("joongna", [sys.executable, os.path.join(script_dir, "joongnaCrawler.py")]),
    ]

    procs: List[Tuple[str, subprocess.Popen]] = []
    threads: List[threading.Thread] = []

    try:
        for name, cmd in cmds:
            proc = subprocess.Popen(
                cmd,
                cwd=script_dir,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )
            procs.append((name, proc))
            t = threading.Thread(target=stream_output, args=(name, proc), daemon=True)
            t.start()
            threads.append(t)

        # Wait for all processes to exit
        exit_codes = {}
        for name, proc in procs:
            code = proc.wait()
            exit_codes[name] = code

        # Join output threads
        for t in threads:
            t.join(timeout=0.2)

        # Print summary
        print("\nSummary:")
        for name, code in exit_codes.items():
            print(f" - {name}: exit code {code}")

        # Non-zero if any failed
        return 0 if all(code == 0 for code in exit_codes.values()) else 1

    except KeyboardInterrupt:
        print("\nKeyboardInterrupt received. Terminating crawlers...")
        for name, proc in procs:
            try:
                proc.terminate()
            except Exception:
                pass
        for name, proc in procs:
            try:
                proc.wait(timeout=5)
            except Exception:
                try:
                    proc.kill()
                except Exception:
                    pass
        return 130


if __name__ == "__main__":
    sys.exit(main())

