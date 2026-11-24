"""Embed the original Python scanner in the standalone interactive script."""

import argparse
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LEGACY = ROOT / "reality_neighbor.sh"
MANAGER = ROOT / "interactive" / "reality_manager.sh"
LEGACY_START = b"""  python3 - "$MAX_TEST_CANDIDATES" "$result_file" <<'PYEOF'\n"""
MANAGER_START = b"\nPYTHON\n# Generated from reality_neighbor.sh by tools/sync_neighbor_scanner.py.\n"
MANAGER_END = b"\nNEIGHBOR_SCANNER\n"


def split_heredoc(content, start, end):
    before, opening, source = content.partition(start)
    body, closing, after = source.partition(end)
    if not opening or not closing:
        raise SystemExit("Scanner heredoc markers are missing")
    return before + opening, body, closing + after


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Check the embedded copy without writing")
    args = parser.parse_args()
    _, scanner, _ = split_heredoc(LEGACY.read_bytes(), LEGACY_START, b"\nPYEOF\n")
    if b"NEIGHBOR_SCANNER" in scanner.splitlines():
        raise SystemExit("Scanner body contains the interactive heredoc delimiter")

    original = MANAGER.read_bytes()
    prefix, _, suffix = split_heredoc(original, MANAGER_START, MANAGER_END)
    updated = prefix + scanner + suffix
    if updated != original:
        if args.check:
            raise SystemExit("Embedded scanner differs. Run python3 tools/sync_neighbor_scanner.py.")
        MANAGER.write_bytes(updated)


if __name__ == "__main__":
    main()
