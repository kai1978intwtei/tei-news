/* Front-end logic for CF3D Studio. */

const $ = sel => document.querySelector(sel);
const fileInput = $('#file-input');
const dropZone = $('#drop-zone');
const fileNameEl = $('#filename');
const btnAnalyze = $('#btn-analyze');
const overlay = $('#overlay');
const lightbox = $('#lightbox');
const lightboxImg = $('#lightbox-img');

let chosenFile = null;
let currentJob = null;
let context = {
  annual_volume: 500,
  quality: 'A',
  application: 'structural',
  matrix: 'epoxy',
};

/* ---------- file pick ---------- */
fileInput.addEventListener('change', e => setFile(e.target.files[0]));
dropZone.addEventListener('click', () => fileInput.click());
['dragenter', 'dragover'].forEach(t =>
  dropZone.addEventListener(t, e => { e.preventDefault(); dropZone.classList.add('dragover'); })
);
['dragleave', 'drop'].forEach(t =>
  dropZone.addEventListener(t, e => { e.preventDefault(); dropZone.classList.remove('dragover'); })
);
dropZone.addEventListener('drop', e => {
  if (e.dataTransfer.files.length) setFile(e.dataTransfer.files[0]);
});
function setFile(f) {
  if (!f) return;
  chosenFile = f;
  fileNameEl.textContent = `${f.name}  ·  ${(f.size / 1024).toFixed(1)} KB`;
}

/* ---------- segmented controls ---------- */
document.querySelectorAll('.seg').forEach(seg => {
  seg.addEventListener('click', e => {
    const btn = e.target.closest('button'); if (!btn) return;
    seg.querySelectorAll('button').forEach(b => b.classList.remove('active'));
    btn.classList.add('active');
    context[seg.dataset.target] = btn.dataset.v;
  });
});
$('#annual_volume').addEventListener('change',
  e => context.annual_volume = parseInt(e.target.value, 10) || 1);

/* ---------- theme ---------- */
$('#btn-theme').addEventListener('click', () => {
  const t = document.documentElement.getAttribute('data-theme') === 'light' ? '' : 'light';
  if (t) document.documentElement.setAttribute('data-theme', t);
  else   document.documentElement.removeAttribute('data-theme');
});

/* ---------- analyze ---------- */
btnAnalyze.addEventListener('click', async () => {
  if (!chosenFile) {
    fileNameEl.textContent = '請先選擇圖紙';
    fileNameEl.style.color = 'var(--warn)';
    return;
  }
  const fd = new FormData();
  fd.append('file', chosenFile);
  fd.append('annual_volume', context.annual_volume);
  fd.append('quality', context.quality);
  fd.append('application', context.application);
  fd.append('matrix', context.matrix);

  overlay.classList.remove('hidden');
  $('#overlay-title').textContent = '分析中…';
  $('#overlay-msg').textContent = '建置 3D 模型 · 評估 10 種碳纖製程 · 規劃疊構';

  try {
    const res = await fetch('/api/analyze', { method: 'POST', body: fd });
    const data = await res.json();
    if (data.status !== 'ok') throw new Error(data.error || 'Analysis failed');
    currentJob = data;
    render(data);
    if (window.cf3dViewer) await window.cf3dViewer.loadJob(jobIdFrom(data));
  } catch (err) {
    console.error(err);
    $('#overlay-title').textContent = '分析失敗';
    $('#overlay-msg').textContent = err.message;
    setTimeout(() => overlay.classList.add('hidden'), 2200);
    return;
  }
  overlay.classList.add('hidden');
});

function jobIdFrom(job) {
  return job.out_dir.split(/[\\/]/).filter(Boolean).pop();
}

/* ---------- render results ---------- */
function render(job) {
  const r = job.report;
  $('#kpi-process').textContent = r.recommendations[0]?.process || '—';
  $('#kpi-fitness').textContent = r.recommendations[0]
      ? (r.recommendations[0].fitness * 100).toFixed(0) + '%' : '—';
  $('#kpi-modulus').textContent = r.layup
      ? r.layup.equivalent_modulus_gpa.toFixed(1) + ' GPa' : '—';

  const recs = $('#recs'); recs.innerHTML = '';
  r.recommendations.forEach((rec, i) => {
    const el = document.createElement('div'); el.className = 'rec';
    el.innerHTML = `
      <div class="rec-head">
        <div class="rec-rank">${i + 1}</div>
        <div class="rec-name">${rec.process}</div>
        <div class="rec-fit">${(rec.fitness * 100).toFixed(0)}%</div>
      </div>
      <div class="rec-bar"><div style="width:${rec.fitness * 100}%"></div></div>
      <div class="rec-meta">
        <span>${rec.family}</span>
        <span>Vf ${rec.fiber_volume_pct[0]}–${rec.fiber_volume_pct[1]}%</span>
        <span>±${rec.tolerance_capability_mm} mm</span>
        <span>cycle ${rec.cycle_time_min[0]}–${rec.cycle_time_min[1]} min</span>
      </div>
      <div class="rec-meta" style="color:var(--text-1)">${rec.rationale}</div>
    `;
    recs.appendChild(el);
  });

  const g = r.geometry;
  $('#geom').innerHTML = `
    <div class="row"><span class="lbl">外形包絡</span><span class="val">${g.length_mm.toFixed(1)} × ${g.width_mm.toFixed(1)} × ${g.height_mm.toFixed(1)} mm</span></div>
    <div class="row"><span class="lbl">壁厚</span><span class="val">${g.nominal_thickness_mm.toFixed(2)} mm (${g.thickness_class})</span></div>
    <div class="row"><span class="lbl">體積 / 表面積</span><span class="val">${g.volume_mm3.toFixed(0)} mm³ / ${g.surface_area_mm2.toFixed(0)} mm²</span></div>
    <div class="row"><span class="lbl">最小圓角</span><span class="val">${g.min_radius_mm ?? '—'} mm</span></div>
    <div class="row"><span class="lbl">複合曲率 / 倒勾</span><span class="val">${g.compound_curvature ? '是' : '否'} / ${g.undercuts ? '是' : '否'}</span></div>
    <div class="row"><span class="lbl">孔特徵 / 封閉斷面</span><span class="val">${g.n_holes} 處 / ${g.closed_section ? '是' : '否'}</span></div>
  `;

  const lyp = r.layup;
  const colors = { '0': '#ff5252', '45': '#ffd54f', '-45': '#26c6da', '90': '#7e57c2',
                    '55': '#66bb6a', '-55': '#42a5f5' };
  const chips = lyp.ply_book.map(p =>
    `<span class="ply-chip" style="background:${colors[p.angle_deg] || '#90a4ae'}">${p.angle_deg >= 0 ? '+' : ''}${p.angle_deg}</span>`
  ).join('');
  $('#layup').innerHTML = `
    <div class="row"><span class="lbl">纖維</span><span class="val">${lyp.fiber_grade}</span></div>
    <div class="row"><span class="lbl">材料形式</span><span class="val">${lyp.fiber_form}</span></div>
    <div class="row"><span class="lbl">疊構</span><span class="val">${lyp.stacking}</span></div>
    <div class="row"><span class="lbl">層數 / 厚度</span><span class="val">${lyp.n_plies} ply / ${lyp.cured_thickness_mm.toFixed(2)} mm</span></div>
    <div class="row"><span class="lbl">Vf / 等效模量</span><span class="val">${lyp.fiber_volume_pct.toFixed(0)}% / ${lyp.equivalent_modulus_gpa.toFixed(1)} GPa</span></div>
    <div class="ply-stack">${chips}</div>
  `;

  const mf = r.recommendations[0]?.moldflow;
  if (mf) {
    $('#moldflow-card').hidden = false;
    $('#moldflow').innerHTML = `
      <div class="row"><span class="lbl">預成型體</span><span class="val">${mf.preform}</span></div>
      <div class="row"><span class="lbl">樹脂系統</span><span class="val">${mf.resin}</span></div>
      <div class="row"><span class="lbl">注射壓力 / 黏度</span><span class="val">${mf.injection_pressure_bar.toFixed(1)} bar / ${mf.viscosity_pas.toFixed(3)} Pa·s</span></div>
      <div class="row"><span class="lbl">預估填充時間</span><span class="val">${mf.fill_time_s.toFixed(0)} s</span></div>
      <div class="row"><span class="lbl">竄流風險</span><span class="val">${(mf.race_tracking_risk * 100).toFixed(0)} %</span></div>
    `;
  } else {
    $('#moldflow-card').hidden = true;
  }
}

/* ---------- snapshot buttons ---------- */
function openSnap(artefact) {
  if (!currentJob) return;
  const id = jobIdFrom(currentJob);
  lightboxImg.src = `/api/snapshot/${id}/${artefact}`;
  lightbox.classList.remove('hidden');
}
$('#btn-multiview').addEventListener('click', () => openSnap('multiview_png'));
$('#btn-explode-png').addEventListener('click', () => openSnap('ply_explode_png'));
$('#btn-fillmap').addEventListener('click', () => openSnap('moldflow_png'));
$('#btn-html').addEventListener('click', () => {
  if (!currentJob) return;
  const html = currentJob.report?.artefacts && Object.keys(currentJob.report.artefacts)
    .find(k => k.endsWith('_html'));
  // server doesn't expose .html directly; open ISO snapshot as alternative
  openSnap('snapshot_png');
});

/* ---------- viewer chips ---------- */
['iso', 'front', 'top', 'right'].forEach(k => {
  document.getElementById('vt-' + k).addEventListener('click',
    () => window.cf3dViewer && window.cf3dViewer.setView(k));
});
$('#vt-explode').addEventListener('click', () => openSnap('ply_explode_png'));
$('#vt-restore').addEventListener('click', () =>
  currentJob && window.cf3dViewer && window.cf3dViewer.loadJob(jobIdFrom(currentJob)));
