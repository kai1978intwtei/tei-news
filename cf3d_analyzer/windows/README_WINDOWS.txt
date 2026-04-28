CF3D Analyzer - Windows quick start (PORTABLE)
==============================================

The .bat files in this folder are PORTABLE: they auto-detect their
own location, so you can drop the whole "tei-news" folder anywhere
(Desktop, Documents, network drive, USB stick) and they will still
work.

Recommended location for this project
-------------------------------------
  <anywhere>\國際大事件\TEi -3D工程專用3\tei-news\

Folder layout you will end up with
----------------------------------
  國際大事件\TEi -3D工程專用3\
   ├── tei-news\                         <-- the GitHub download
   │    └── cf3d_analyzer\
   │         ├── windows\                <-- the .bat files (here)
   │         ├── examples\
   │         ├── tests\
   │         └── ...
   ├── cf3d_input\                       <-- AUTO-CREATED for your STP/DXF
   └── cf3d_output\                      <-- AUTO-CREATED for reports

Numbered scripts (run them in order the first time)
---------------------------------------------------

  1_install.bat       Run once.  Creates .venv, installs the package +
                      all extras, and creates cf3d_input / cf3d_output
                      next to the tei-news folder.

  2_gui.bat           Launches the desktop GUI.

  3_analyze.bat       Drag any drawing onto THIS FILE in Explorer to
                      analyse it instantly.  Or double-click and paste
                      a path.  Report opens in your browser.

  4_watch.bat         Folder watcher.  Drop drawings into the
                      sibling cf3d_input folder; reports auto-generate
                      in cf3d_output.

  5_open_folders.bat  Open input + output folders in Explorer.

  6_run_tests.bat     Smoke-test suite (8 tests).

Output files per drawing
------------------------
  <name>.report.html       open this first
  <name>.report.json       structured data for PLM / ERP integration
  <name>.report.md         Markdown summary
  <name>.stl / .obj / .ply 3D mesh, openable in any CAD/slicer
  <name>_iso.png           isometric 3D snapshot
  <name>_multiview.png     8-angle inspection montage
  <name>_ply_explode.png   exploded laminate (per-angle colour)
  <name>_moldflow.png      Darcy fill-time map (RTM / infusion only)

Pinning to taskbar
------------------
Right-click 2_gui.bat -> "Pin to taskbar" for a one-click GUI launch.

Troubleshooting
---------------
- "python is not recognized": re-install Python with the
  "Add Python to PATH" box ticked.
- "cf3d is not recognized": close the cmd window and reopen, or just
  use the .bat scripts (they activate .venv automatically).
- DWG files won't import: convert to DXF first (Autodesk DWG TrueView,
  Inventor, SolidWorks Save-As, or ODA File Converter).
- For full B-Rep tessellation of STEP files, run inside the venv:
      pip install cadquery
  (On Windows, conda is more reliable: conda install -c conda-forge cadquery)
