"""Standalone Tkinter desktop GUI.

Pure stdlib — keeps the application installable on locked-down workshop
machines.  Provides:
    - drawing picker
    - project context inputs
    - one-click "Analyze"
    - one-click "Watch folder"
    - 3D snapshot preview, multi-view, ply explode toggle
    - results pane with the top recommendations + layup
    - opens the HTML report in the default browser
"""
from __future__ import annotations

import logging
import threading
import tkinter as tk
import webbrowser
from pathlib import Path
from tkinter import filedialog, messagebox, ttk

from .pipeline import analyze
from .process_advisor import ProjectContext
from .watcher import watch as watch_folder

log = logging.getLogger(__name__)


def launch() -> None:  # pragma: no cover - GUI entry
    root = tk.Tk()
    App(root)
    root.mainloop()


class App:
    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        root.title("CF3D Analyzer — Carbon Fiber Composite Studio")
        root.geometry("1180x780")
        self._explode_factor = tk.DoubleVar(value=4.0)
        self._explode_state = tk.StringVar(value="exploded")
        self._build()

    # ---------------------------------------------------------------- layout
    def _build(self) -> None:
        head = ttk.Frame(self.root, padding=10)
        head.pack(fill=tk.X)
        ttk.Label(head, text="CF3D Analyzer",
                  font=("Helvetica", 16, "bold")).pack(side=tk.LEFT)
        ttk.Label(head,
                  text="Drawing → 3D → Composite Process",
                  font=("Helvetica", 10)).pack(side=tk.LEFT, padx=12)

        body = ttk.PanedWindow(self.root, orient=tk.HORIZONTAL)
        body.pack(fill=tk.BOTH, expand=True, padx=10, pady=8)

        controls = ttk.Frame(body, padding=8)
        body.add(controls, weight=1)

        ttk.Label(controls, text="Drawing").grid(row=0, column=0, sticky="w")
        self.path_var = tk.StringVar()
        ttk.Entry(controls, textvariable=self.path_var, width=42)\
            .grid(row=0, column=1, sticky="ew")
        ttk.Button(controls, text="Browse…", command=self._browse)\
            .grid(row=0, column=2, padx=4)

        opts = ttk.LabelFrame(controls, text="Project context", padding=8)
        opts.grid(row=1, column=0, columnspan=3, sticky="ew", pady=8)
        self.volume = tk.IntVar(value=200)
        self.quality = tk.StringVar(value="A")
        self.application = tk.StringVar(value="structural")
        self.matrix = tk.StringVar(value="epoxy")
        for r, (lab, w) in enumerate([
            ("Annual volume",
             ttk.Spinbox(opts, from_=1, to=1_000_000, textvariable=self.volume)),
            ("Quality grade",
             ttk.Combobox(opts, values=["A", "B", "C"], textvariable=self.quality)),
            ("Application",
             ttk.Combobox(opts,
                          values=["structural", "cosmetic", "pressure"],
                          textvariable=self.application)),
            ("Matrix",
             ttk.Combobox(opts,
                          values=["epoxy", "bmi", "thermoplastic"],
                          textvariable=self.matrix)),
        ]):
            ttk.Label(opts, text=lab).grid(row=r, column=0, sticky="w")
            w.grid(row=r, column=1, sticky="ew", padx=4, pady=2)
        opts.columnconfigure(1, weight=1)

        actions = ttk.Frame(controls)
        actions.grid(row=2, column=0, columnspan=3, sticky="ew", pady=4)
        ttk.Button(actions, text="Analyze ▶",
                   command=self._analyze).pack(side=tk.LEFT, padx=4)
        ttk.Button(actions, text="Watch folder…",
                   command=self._watch).pack(side=tk.LEFT, padx=4)
        ttk.Button(actions, text="Open report",
                   command=self._open_report).pack(side=tk.LEFT, padx=4)

        explode = ttk.LabelFrame(controls, text="Ply explode (one-click)", padding=8)
        explode.grid(row=3, column=0, columnspan=3, sticky="ew", pady=8)
        ttk.Scale(explode, from_=0.0, to=10.0, orient=tk.HORIZONTAL,
                  variable=self._explode_factor,
                  command=lambda *_: None).grid(row=0, column=0, columnspan=2,
                                                 sticky="ew")
        ttk.Button(explode, text="Explode",
                   command=lambda: self._set_explode("exploded"))\
            .grid(row=1, column=0, sticky="ew", padx=4, pady=4)
        ttk.Button(explode, text="Restore",
                   command=lambda: self._set_explode("collapsed"))\
            .grid(row=1, column=1, sticky="ew", padx=4, pady=4)
        explode.columnconfigure(0, weight=1)
        explode.columnconfigure(1, weight=1)

        ttk.Label(controls, text="Output folder").grid(row=4, column=0, sticky="w")
        self.out_var = tk.StringVar(value=str(Path("./cf3d_out").resolve()))
        ttk.Entry(controls, textvariable=self.out_var)\
            .grid(row=4, column=1, sticky="ew")
        ttk.Button(controls, text="…",
                   command=self._pick_out).grid(row=4, column=2, padx=4)
        controls.columnconfigure(1, weight=1)

        # ---------------------------- right pane: notebook with previews
        right = ttk.Notebook(body)
        body.add(right, weight=2)

        self.summary = tk.Text(right, height=20, wrap="word",
                                background="#0d1b2a", foreground="#f0f5ff")
        right.add(self.summary, text="Summary")

        self.iso_frame = ttk.Frame(right)
        right.add(self.iso_frame, text="3D Snapshot")
        self.multi_frame = ttk.Frame(right)
        right.add(self.multi_frame, text="Multi-view")
        self.explode_frame = ttk.Frame(right)
        right.add(self.explode_frame, text="Ply Explode")
        self.flow_frame = ttk.Frame(right)
        right.add(self.flow_frame, text="Mould-flow")

        self.status = tk.StringVar(value="Ready.")
        ttk.Label(self.root, textvariable=self.status, anchor="w",
                  background="#1a3a6e", foreground="#ffffff", padding=6)\
            .pack(fill=tk.X, side=tk.BOTTOM)

        self._last_report = None
        self._image_refs: dict[str, tk.PhotoImage] = {}

    # --------------------------------------------------------------- actions
    def _browse(self) -> None:
        f = filedialog.askopenfilename(filetypes=[
            ("Drawings", "*.dxf *.dwg *.step *.stp *.iges *.igs *.pdf "
                          "*.png *.jpg *.jpeg *.tif *.tiff"),
        ])
        if f:
            self.path_var.set(f)

    def _pick_out(self) -> None:
        d = filedialog.askdirectory()
        if d:
            self.out_var.set(d)

    def _ctx(self) -> ProjectContext:
        return ProjectContext(
            annual_volume=self.volume.get(),
            quality_grade=self.quality.get(),
            application=self.application.get(),
            matrix_class=self.matrix.get(),
            fiber_system="carbon",
        )

    def _analyze(self) -> None:
        path = self.path_var.get().strip()
        if not path:
            messagebox.showwarning("CF3D", "Choose a drawing first")
            return
        self.status.set(f"Analysing {Path(path).name}…")
        threading.Thread(target=self._run_analyze, args=(path,), daemon=True).start()

    def _run_analyze(self, path: str) -> None:
        try:
            rep = analyze(path, ctx=self._ctx(), out_dir=self.out_var.get())
            self._last_report = rep
            self.root.after(0, lambda: self._render_report(rep))
            self.root.after(0, lambda: self.status.set("Ready."))
        except Exception as exc:
            log.exception("GUI analyze failed")
            self.root.after(0, lambda: messagebox.showerror("CF3D", str(exc)))
            self.root.after(0, lambda: self.status.set("Error."))

    def _watch(self) -> None:
        d = filedialog.askdirectory(title="Watch folder for new drawings")
        if not d:
            return
        self.status.set(f"Watching {d}…")
        threading.Thread(
            target=lambda: watch_folder(d, ctx=self._ctx(),
                                          out_dir=self.out_var.get(),
                                          on_report=self._on_watch_report),
            daemon=True,
        ).start()

    def _on_watch_report(self, rep) -> None:
        self.root.after(0, lambda: self._render_report(rep))

    def _set_explode(self, state: str) -> None:
        self._explode_state.set(state)
        if not self._last_report:
            self.status.set("Run an analysis first.")
            return
        from PIL import Image, ImageTk  # type: ignore
        try:
            key = ("ply_explode_png" if state == "exploded"
                   else "snapshot_png")
            png = self._last_report.artefacts.get(key)
            if png:
                self._show_png(png, self.explode_frame, "explode")
                self.status.set(
                    f"Stack {'exploded' if state == 'exploded' else 'restored'} "
                    f"(factor={self._explode_factor.get():.1f})")
        except ImportError:
            self.status.set("Install Pillow for in-window preview.")

    def _open_report(self) -> None:
        if not self._last_report:
            messagebox.showinfo("CF3D", "Run an analysis first")
            return
        html = (Path(self.out_var.get())
                / f"{Path(self._last_report.source).stem}.report.html")
        if html.exists():
            webbrowser.open(html.as_uri())

    # --------------------------------------------------------------- render
    def _render_report(self, rep) -> None:
        self.summary.delete("1.0", tk.END)
        lines = [f"Source : {rep.source}",
                 f"Method : {rep.reconstruction['method']}  "
                 f"(confidence {rep.reconstruction['confidence']:.0%})",
                 f"BBox   : {rep.geometry['length_mm']:.1f} × "
                 f"{rep.geometry['width_mm']:.1f} × "
                 f"{rep.geometry['height_mm']:.1f} mm",
                 f"Wall   : {rep.geometry['nominal_thickness_mm']:.2f} mm "
                 f"({rep.geometry['thickness_class']})",
                 ""]
        lines.append("=== Recommended composite processes ===")
        for r in rep.recommendations:
            lines.append(f"  #{r['rank']} {r['process']:<40s}  "
                          f"fitness {r['fitness']:.2f}")
            lines.append(f"     {r['rationale']}")
            mf = r.get("moldflow")
            if mf:
                lines.append(f"     mold-fill ≈ {mf['fill_time_s']:.0f}s @ "
                              f"{mf['injection_pressure_bar']:.1f} bar  "
                              f"(race-tracking risk {mf['race_tracking_risk']:.0%})")
        lines.append("")
        lines.append("=== Suggested CF layup ===")
        lyp = rep.layup
        lines.append(f"  Fiber  : {lyp['fiber_grade']}  "
                      f"({lyp['fiber_modulus_gpa']} GPa / "
                      f"{lyp['fiber_strength_mpa']} MPa)")
        lines.append(f"  Stack  : {lyp['stacking']}  "
                      f"({lyp['n_plies']} plies, "
                      f"{lyp['cured_thickness_mm']:.2f} mm cured)")
        lines.append(f"  Modulus: {lyp['equivalent_modulus_gpa']} GPa "
                      f"(in-plane equivalent)")
        self.summary.insert("1.0", "\n".join(lines))

        for k, frame in [("snapshot_png", self.iso_frame),
                         ("multiview_png", self.multi_frame),
                         ("ply_explode_png", self.explode_frame),
                         ("moldflow_png", self.flow_frame)]:
            png = rep.artefacts.get(k)
            if png:
                self._show_png(png, frame, k)

    def _show_png(self, png_path: str, frame: ttk.Frame, key: str) -> None:
        try:
            from PIL import Image, ImageTk  # type: ignore
        except ImportError:
            for w in frame.winfo_children():
                w.destroy()
            ttk.Label(frame, text=f"PIL not installed — open {png_path} externally")\
                .pack(padx=12, pady=12)
            return
        for w in frame.winfo_children():
            w.destroy()
        img = Image.open(png_path)
        img.thumbnail((720, 540))
        tk_img = ImageTk.PhotoImage(img)
        self._image_refs[key] = tk_img
        ttk.Label(frame, image=tk_img).pack(padx=8, pady=8)
