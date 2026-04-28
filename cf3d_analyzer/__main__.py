"""`python -m cf3d_analyzer` entry point."""
import sys

from .cli.main import main

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
