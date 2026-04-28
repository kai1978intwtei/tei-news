// Three.js interactive viewer.  Loaded as ES module via importmap.
import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { STLLoader } from 'three/addons/loaders/STLLoader.js';

const host = document.getElementById('three-host');
const ghost = document.getElementById('ghost-msg');
const foot = document.getElementById('viewer-foot');

let scene, camera, renderer, controls, currentMesh = null;

function init() {
  scene = new THREE.Scene();
  scene.background = null;
  scene.fog = new THREE.FogExp2(0x070b18, 0.0025);

  const w = host.clientWidth, h = host.clientHeight;
  camera = new THREE.PerspectiveCamera(45, w / h, 0.1, 8000);
  camera.position.set(280, 220, 320);

  renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
  renderer.setSize(w, h);
  renderer.toneMapping = THREE.ACESFilmicToneMapping;
  renderer.toneMappingExposure = 1.05;
  host.appendChild(renderer.domElement);

  controls = new OrbitControls(camera, renderer.domElement);
  controls.enableDamping = true;
  controls.dampingFactor = 0.07;

  // lights
  const hemi = new THREE.HemisphereLight(0x9bb6ff, 0x1a2238, 0.7);
  scene.add(hemi);
  const key = new THREE.DirectionalLight(0xffffff, 1.1);
  key.position.set(220, 320, 180);
  scene.add(key);
  const rim = new THREE.DirectionalLight(0x7c5cff, 0.55);
  rim.position.set(-200, 80, -250);
  scene.add(rim);

  // ground plane (subtle)
  const grid = new THREE.GridHelper(2000, 80, 0x223055, 0x12182c);
  grid.position.y = -2;
  scene.add(grid);

  window.addEventListener('resize', resize);
  animate();
}

function resize() {
  const w = host.clientWidth, h = host.clientHeight;
  camera.aspect = w / h;
  camera.updateProjectionMatrix();
  renderer.setSize(w, h);
}

function animate() {
  requestAnimationFrame(animate);
  controls.update();
  renderer.render(scene, camera);
}

function disposeMesh() {
  if (!currentMesh) return;
  scene.remove(currentMesh);
  currentMesh.traverse(o => {
    if (o.geometry) o.geometry.dispose();
    if (o.material) {
      if (Array.isArray(o.material)) o.material.forEach(m => m.dispose());
      else o.material.dispose();
    }
  });
  currentMesh = null;
}

function frameObject(obj) {
  const box = new THREE.Box3().setFromObject(obj);
  const size = new THREE.Vector3(); box.getSize(size);
  const center = new THREE.Vector3(); box.getCenter(center);
  obj.position.sub(center);
  const radius = size.length() / 2;
  const dist = radius / Math.sin((camera.fov * Math.PI / 180) / 2) * 1.2;
  camera.position.set(dist * 0.7, dist * 0.55, dist * 0.85);
  camera.lookAt(0, 0, 0);
  controls.target.set(0, 0, 0);
  controls.update();
  foot.textContent = `Bbox  ${size.x.toFixed(1)} × ${size.y.toFixed(1)} × ${size.z.toFixed(1)} mm   ·   centre (${center.x.toFixed(1)}, ${center.y.toFixed(1)}, ${center.z.toFixed(1)})`;
}

function makeMaterial() {
  return new THREE.MeshPhysicalMaterial({
    color: 0x2a3550,
    metalness: 0.55,
    roughness: 0.32,
    clearcoat: 0.6,
    clearcoatRoughness: 0.25,
    sheen: 0.2,
    sheenColor: 0x5ac8fa,
    side: THREE.DoubleSide,
    flatShading: false,
  });
}

function loadFromBuffer(buffer, kind) {
  disposeMesh();
  ghost.style.display = 'none';
  let geom;
  if (kind === 'glb' || kind === 'gltf') {
    const loader = new GLTFLoader();
    loader.parse(buffer, '', gltf => {
      gltf.scene.traverse(c => {
        if (c.isMesh) c.material = makeMaterial();
      });
      currentMesh = gltf.scene;
      scene.add(currentMesh);
      frameObject(currentMesh);
    });
  } else {
    geom = new STLLoader().parse(buffer);
    geom.computeVertexNormals();
    const mesh = new THREE.Mesh(geom, makeMaterial());
    const wire = new THREE.LineSegments(
      new THREE.EdgesGeometry(geom, 30),
      new THREE.LineBasicMaterial({ color: 0x5ac8fa, transparent: true, opacity: 0.18 })
    );
    const grp = new THREE.Group();
    grp.add(mesh); grp.add(wire);
    currentMesh = grp;
    scene.add(currentMesh);
    frameObject(currentMesh);
  }
}

export function setView(kind) {
  if (!currentMesh) return;
  const box = new THREE.Box3().setFromObject(currentMesh);
  const size = new THREE.Vector3(); box.getSize(size);
  const r = size.length();
  const cam = camera;
  switch (kind) {
    case 'iso':   cam.position.set( r, r * 0.8,  r); break;
    case 'front': cam.position.set( 0, 0,  r * 1.4); break;
    case 'top':   cam.position.set( 0, r * 1.4, 0.001); break;
    case 'right': cam.position.set( r * 1.4, 0, 0); break;
  }
  controls.target.set(0, 0, 0);
  cam.lookAt(0, 0, 0);
}

export async function loadJob(jobId) {
  const url = `/api/mesh/${jobId}`;
  const head = await fetch(url, { method: 'HEAD' });
  if (!head.ok) return;
  const ct = head.headers.get('content-type') || '';
  const buf = await (await fetch(url)).arrayBuffer();
  const isGlb = ct.includes('gltf') || ct.includes('glb') || ct.includes('octet');
  // Try GLB first, fall back to STL parse if it fails.
  try {
    if (isGlb) loadFromBuffer(buf, 'glb');
    else loadFromBuffer(buf, 'stl');
  } catch (e) {
    console.warn('GLB parse failed, retrying as STL', e);
    loadFromBuffer(buf, 'stl');
  }
}

window.cf3dViewer = { loadJob, setView };
init();
