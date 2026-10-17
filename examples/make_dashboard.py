"""Reproduce the redesigned SukukLab snapshot without Julia.
Uses the source Julia cash-flow/rate formulas through portfolio_ui/renderer.py.
Requires beautifulsoup4. Run from anywhere: python examples/make_dashboard.py
"""
from pathlib import Path
import sys
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/"portfolio_ui"))
from renderer import render
render(ROOT,"sukuklab",ROOT/"portfolio_ui"/"julia-source-snapshot.html",ROOT/"docs"/"dashboard.html")
