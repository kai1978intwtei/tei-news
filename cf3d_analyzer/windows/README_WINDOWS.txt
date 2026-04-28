CF3D Analyzer - Windows quick start
====================================

Numbered scripts in this folder map to the order you'll use them:

  1_install.bat       Run once.  Creates .venv, installs the package +
                      all extras (matplotlib, ezdxf, PyMuPDF, opencv,
                      trimesh).  Also creates Desktop\cf3d_input and
                      Desktop\cf3d_output.

  2_gui.bat           Launches the desktop GUI.  Browse to a drawing,
                      pick options, click Analyze.

  3_analyze.bat       Drag any .stp / .step / .dxf / .pdf / .png onto
                      THIS FILE in Explorer to analyse it in one shot.
                      Or double-click and paste a path when prompted.
                      Report opens automatically in your browser.

  4_watch.bat         Folder watcher.  Drop drawings into
                      Desktop\cf3d_input - reports auto-generate in
                      Desktop\cf3d_output.

  5_open_folders.bat  Open the input + output folders in Explorer.

  6_run_tests.bat     Run the smoke-test suite (8 tests).  Use this if
                      anything looks wrong after the install.

Where things go
---------------
Drawings   ->  %USERPROFILE%\Desktop\cf3d_input
Reports    ->  %USERPROFILE%\Desktop\cf3d_output
Software   ->  this folder's parent (cf3d_analyzer)

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
- "cf3d is not recognized": close the cmd window and reopen, or run
  the .bat scripts (they activate .venv automatically).
- DWG files won't import: convert to DXF first (Autodesk DWG
  TrueView, Inventor, SolidWorks Save-As, or ODA File Converter).
- For full B-Rep tessellation of STEP files (instead of envelope
  proxy), open a CMD inside this folder and run:
      .venv\Scripts\activate
      pip install cadquery
  (On Windows, conda is more reliable: conda install -c conda-forge cadquery)
