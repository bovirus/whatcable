// Electrical reference connections with exploded geometry for inspection.
const $ = (id) => document.getElementById(id);
const state = { cable: 'thunderbolt', selected: null, open: .75, differences: false, wire: null };
let viewer;
let data;
const status = $('scene-status');
function clearGuide() {
  $('question-answer').hidden = true;
  document.querySelectorAll('[data-question]').forEach(b=>b.setAttribute('aria-pressed','false'));
}
function selectWire(pin) {
  const connection = data.connections.find(c=>c.from.split(', ').includes(pin));
  if (!connection) return;
  selectPart(connection.part);
  state.wire = pin;
  $('wire-select').value = connection.from;
  $('wire-description').hidden = false;
  $('wire-description').textContent = `${connection.signal}: plug 1 ${connection.from} → plug 2 ${connection.to}.`;
  $('selection-status').textContent = $('wire-description').textContent;
  document.querySelectorAll('[data-connection]').forEach(row=>row.dataset.traced=String(row.dataset.from===connection.from));
  viewer?.highlight();
}
function clearSelection() {
  state.selected=null;state.wire=null;clearGuide();
  $('wire-select').value='';$('wire-description').hidden=true;
  $('part-name').textContent='Explore a component';
  $('part-summary').textContent='Select a part of the cable or choose a component from the list to learn how it works.';
  $('part-details').hidden=true;$('part-details').open=false;$('part-whatcable').hidden=true;
  $('clear-selection').disabled=true;
  $('selection-status').textContent='Select a component to trace its role.';
  document.querySelectorAll('[data-part]').forEach(b=>b.setAttribute('aria-pressed','false'));
  document.querySelectorAll('[data-connection]').forEach(row=>row.dataset.traced='false');
  viewer?.highlight();
}
function selectPart(id) {
  $('clear-selection').disabled=false;
  state.wire = null;
  $('wire-select').value = '';
  $('wire-description').hidden = true;
  document.querySelectorAll('[data-connection]').forEach(row=>row.dataset.traced='false');
  const part = { ...data.parts.find(p => p.id === id), ...data.cables[state.cable].partOverrides?.[id] };
  if(state.selected!==id)$('part-details').open=false;
  state.selected = id;
  $('selection-status').textContent = `Selected: ${part.name}`;
  $('part-source').textContent = part.sourceLabel;
  $('part-source').href = part.sourceUrl;
  document.querySelectorAll('[data-part]').forEach(b => b.setAttribute('aria-pressed', String(b.dataset.part === id)));
  $('part-details').hidden = false;
  $('part-name').textContent = part.name;
  $('part-summary').textContent = part.summary;
  $('part-detail').textContent = part.detail;
  $('part-whatcable-detail').textContent = part.whatcableDetail || '';
  $('part-whatcable-detail').hidden = !part.whatcableDetail;
  $('part-whatcable').hidden = !part.whatcable;
  $('part-whatcable-text').textContent = part.whatcable || '';
  if (window.matchMedia?.('(max-width:850px)').matches) {
    const explanation=$('component-explanation');
    if(explanation.getBoundingClientRect().top < 80) explanation.scrollIntoView({block:'start',behavior:'instant'});
  }
  if (id === 'marker' && state.open < .85) {
    state.open = .85;
    $('cutaway').value = '85';
    $('cutaway-value').value = '85%';
    viewer?.rebuild();
  } else viewer?.highlight();
}
function selectCable(id) {
  state.cable = id;
  document.querySelectorAll('#wire-select option[data-basic]').forEach(option=>{ option.hidden = option.disabled = id==='basic' && option.dataset.basic==='false'; });
  const cable = data.cables[id];
  document.querySelectorAll('[data-cable]').forEach(b => b.setAttribute('aria-pressed', String(b.dataset.cable === id)));
  document.querySelectorAll('[data-part]').forEach(b => { b.hidden = id === 'basic' && data.parts.find(p => p.id === b.dataset.part).extra === true; });
  $('model-name').textContent = cable.name;
  $('cap-data').textContent = cable.data;
  $('cap-power').textContent = cable.power;
  $('cap-video').textContent = cable.video;
  $('parts-count').textContent = `${data.parts.filter(p => id !== 'basic' || !p.extra).length} groups`;
  document.querySelectorAll('.connection-guide tr[data-basic]').forEach(row => { row.hidden = id === 'basic' && row.dataset.basic === 'false'; });
  $('comparison-title').textContent = `Inside the ${cable.name} example`;
  $('comparison-description').textContent = cable.description;
  $('tb5-bandwidth').hidden = id !== 'thunderbolt5';
  if (id === 'basic' && data.parts.find(p => p.id === state.selected)?.extra) selectPart('usb2');
  else if (state.wire) selectWire(state.wire);
  else if (state.selected) selectPart(state.selected);
  viewer?.rebuild();
}
async function init() {
  try {
    const response = await fetch(new URL('./cables.json', import.meta.url));
    if (!response.ok) throw new Error('Cable descriptions unavailable');
    data = await response.json();
  } catch (error) {
    status.textContent = 'The explorer could not load. You can still read the full component guide below.';
    document.querySelectorAll('[data-cable], [data-part], [data-question], #wire-select, #cutaway, #differences, #reset-view, #connector-view').forEach(b => b.disabled = true);
    return;
  }
  $('clear-selection').addEventListener('click',clearSelection);
  document.querySelectorAll('[data-bandwidth]').forEach(button=>button.addEventListener('click',()=>{
    const boost=button.dataset.bandwidth==='boost';
    document.querySelectorAll('[data-bandwidth]').forEach(b=>b.setAttribute('aria-pressed',String(b===button)));
    $('bandwidth-out').textContent=boost?'120 Gbps →':'80 Gbps →';
    $('bandwidth-back').textContent=boost?'← 40 Gbps':'← 80 Gbps';
    $('bandwidth-lanes').textContent=boost?'3 lanes towards displays · 1 lane back':'2 lanes each way';
    $('bandwidth-explanation').textContent=boost?'Bandwidth Boost reallocates one lane for display-heavy traffic. It provides 120 Gbps in one direction and 40 Gbps in the other.':'Normal operation provides 80 Gbps in each direction at the same time.';
  }));
  $('end-guide').addEventListener('click',()=>{
    const question=document.querySelector('[data-question][aria-pressed="true"]');
    clearGuide();question?.focus();
  });
  $('wire-select').addEventListener('change',e=>{clearGuide();if(e.target.value)selectWire(e.target.value.split(', ')[0]);else if(state.selected)selectPart(state.selected);});
  document.querySelectorAll('[data-question]').forEach(button=>button.addEventListener('click',()=>{
    const question=data.questions.find(q=>q.id===button.dataset.question);
    selectCable(question.cable);
    state.open=.9;$('cutaway').value='90';$('cutaway-value').value='90%';
    selectPart(question.part);viewer?.rebuild();
    if(question.id==='identity')viewer?.closeUp();else viewer?.reset();
    $('question-title').textContent=question.title;$('question-text').textContent=question.text;
    $('question-answer').hidden=false;
    document.querySelectorAll('[data-question]').forEach(b=>b.setAttribute('aria-pressed',String(b===button)));
  }));
  $('marker-callout').addEventListener('click', () => selectPart('marker'));
  document.querySelectorAll('[data-part]').forEach(b => b.addEventListener('click', () => {clearGuide();selectPart(b.dataset.part);}));
  document.querySelectorAll('[data-cable]').forEach(b => b.addEventListener('click', () => {clearGuide();selectCable(b.dataset.cable);}));
  $('cutaway').addEventListener('input', e => {
    state.open = Number(e.target.value) / 100;
    $('cutaway-value').value = `${e.target.value}%`;
    viewer?.rebuild();
  });
  $('differences').addEventListener('change', e => {
    state.differences = e.target.checked;
    $('difference-note').hidden = !state.differences;
    $('comparison-key').hidden = !state.differences;
    viewer?.highlight();
  });
  try {
    const [THREE, { OrbitControls }] = await Promise.all([import('three'), import('./vendor/OrbitControls.js')]);
    viewer = createViewer(THREE, OrbitControls);
    viewer.rebuild();
    status.hidden = true;
  } catch (error) {
    console.error('Cable viewer:', error);
    status.textContent = '3D is unavailable in this browser. Switch cables and use the component buttons to explore the same information.';
    $('cutaway').disabled = true;
    $('reset-view').disabled = true;
    $('connector-view').disabled = true;
  }
}
function createViewer(T, OrbitControls) {
  const host = $('scene');
  const renderer = new T.WebGLRenderer({ antialias: true, alpha: true });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
  renderer.setClearColor(0xffffff, 0);
  renderer.outputColorSpace = T.SRGBColorSpace;
  renderer.toneMapping = T.ACESFilmicToneMapping;
  host.appendChild(renderer.domElement);
  const scene = new T.Scene();
  const camera = new T.PerspectiveCamera(36, 1, .1, 100);
  const controls = new OrbitControls(camera, renderer.domElement);
  controls.enableDamping = false;
  controls.enablePan = false;
  controls.minDistance = 1.2;
  controls.maxDistance = 26;
  controls.target.set(.1, 0, 0);
  scene.add(new T.HemisphereLight(0xffffff, 0x6a7a91, 3));
  const light = new T.DirectionalLight(0xffffff, 4); light.position.set(1, 6, 7); scene.add(light);
  const rim = new T.DirectionalLight(0xb3deff, 2); rim.position.set(-4, 0, -4); scene.add(rim);
  let assembly = new T.Group(); scene.add(assembly);
  let pickable = [];
  function render() {
    // Draw on interaction: background Safari windows can suspend animation frames.
      renderer.render(scene, camera);
      const label = $('marker-callout');
      const anchor = new T.Vector3(2.76, .08, .18).project(camera);
      label.hidden = state.cable === 'basic'
        || (state.selected !== 'marker' && !state.differences)
        || state.open < .2
        || Math.abs(anchor.x) > 1 || Math.abs(anchor.y) > 1
        || anchor.z > 1 || anchor.z < -1;
      label.style.left = `${Math.max(90, Math.min(host.clientWidth - 90, (anchor.x + 1) / 2 * host.clientWidth))}px`;
      label.style.top = `${Math.max(110, Math.min(host.clientHeight - 70, (1 - anchor.y) / 2 * host.clientHeight - 24))}px`;
  }
  controls.addEventListener('change', render);
  function reset() {
    $('connector-view').setAttribute('aria-pressed','false');
    const aspect = host.clientWidth / host.clientHeight;
    camera.position.set(5, 3.8, aspect < 1.2 ? 16 : 12);
    controls.target.set(.1, 0, 0);
    controls.update(); render();
  }
  function resize() {
    camera.aspect = host.clientWidth / host.clientHeight;
    camera.updateProjectionMatrix();
    renderer.setSize(host.clientWidth, host.clientHeight, false);
    render();
  }
  const observer = new ResizeObserver(resize); observer.observe(host);
  reset(); resize();
  function closeUp() {
    state.open=Math.max(.85,state.open);$('cutaway').value=String(Math.round(state.open*100));$('cutaway-value').value=`${Math.round(state.open*100)}%`;
    rebuild();camera.position.set(3.9,1.3,3.2);controls.target.set(3.05,0,.04);controls.update();
    $('connector-view').setAttribute('aria-pressed','true');render();
  }
  $('connector-view').addEventListener('click',closeUp);
  $('reset-view').addEventListener('click', reset);
  renderer.domElement.tabIndex=0;
  renderer.domElement.setAttribute('role','img');
  renderer.domElement.setAttribute('aria-label','3D cable. Arrow keys rotate; plus and minus zoom. Select components using the adjacent list.');
  renderer.domElement.addEventListener('keydown',e=>{
    if(!['ArrowLeft','ArrowRight','ArrowUp','ArrowDown','+','=','-'].includes(e.key))return;
    e.preventDefault();
    const offset=camera.position.clone().sub(controls.target);const sphere=new T.Spherical().setFromVector3(offset);
    if(e.key==='ArrowLeft')sphere.theta-=.12;if(e.key==='ArrowRight')sphere.theta+=.12;
    if(e.key==='ArrowUp')sphere.phi-=.12;if(e.key==='ArrowDown')sphere.phi+=.12;
    if(e.key==='+'||e.key==='=')sphere.radius*=.9;if(e.key==='-')sphere.radius*=1.1;
    sphere.makeSafe();sphere.radius=T.MathUtils.clamp(sphere.radius,controls.minDistance,controls.maxDistance);
    camera.position.copy(controls.target).add(new T.Vector3().setFromSpherical(sphere));controls.update();render();
  });
  renderer.domElement.addEventListener('webglcontextlost', e => {
    e.preventDefault(); status.hidden = false; $('marker-callout').hidden = true;
    status.textContent = 'The 3D view was interrupted. The component guide still works. Reload to restore 3D.';
  });
  const raycaster = new T.Raycaster();
  let pointerStart;
  renderer.domElement.addEventListener('pointerdown', e => { pointerStart = [e.clientX, e.clientY]; });
  renderer.domElement.addEventListener('pointerup', e => {
    if (!pointerStart || Math.hypot(e.clientX - pointerStart[0], e.clientY - pointerStart[1]) > 6) return;
    const rect = renderer.domElement.getBoundingClientRect();
    raycaster.setFromCamera(new T.Vector2((e.clientX - rect.left) / rect.width * 2 - 1, -(e.clientY - rect.top) / rect.height * 2 + 1), camera);
    const hit = raycaster.intersectObjects(pickable).find(h => h.object.material.opacity > .25);
    if(hit?.object.userData.wirePin){clearGuide();selectWire(hit.object.userData.wirePin);}
    else if (hit?.object.userData.part) {clearGuide();selectPart(hit.object.userData.part);}
  });
  function material(color, metalness = .1) { return new T.MeshStandardMaterial({color, roughness: .38, metalness, side: T.DoubleSide}); }
  function mesh(geometry, color, part, metalness = .1) {
    const obj = new T.Mesh(geometry, material(color, metalness));
    obj.userData.part = part;
    obj.userData.base = new T.Color(color);
    assembly.add(obj);
    if (part) pickable.push(obj);
    return obj;
  }
  function cylinder(x, length, radius, color, part, arc = Math.PI * 2) {
    const obj = mesh(new T.CylinderGeometry(radius, radius, length, 48, 1, true, 0, arc), color, part, part === 'shield' ? .8 : .15);
    obj.rotation.z = Math.PI / 2; obj.position.x = x;
    return obj;
  }
  function box(x, y, z, sx, sy, sz, color, part, metalness = .1) {
    const obj = mesh(new T.BoxGeometry(sx, sy, sz), color, part, metalness);
    obj.position.set(x, y, z); return obj;
  }
  function path(points, radius, color, part) {
    return mesh(new T.TubeGeometry(new T.CatmullRomCurve3(points.map(p => new T.Vector3(...p))), 42, radius, 8, false), color, part);
  }
  function contact(pin, x = 3.9) {
    const number = Number(pin.slice(1));
    // Opposing rows run in opposite directions when looking into the plug.
    return [x, (number - 6.5) * .056 * (pin[0] === 'A' ? 1 : -1), pin[0] === 'A' ? .085 : -.085];
  }
  function route(part, color, lane, radius, pin, coax = false) {
    const packedY = lane * .21;
    const jacketEnd = 2.45 - state.open * 4.9;
    const sleeveEnd = Math.min(2.5, jacketEnd + .18 + .45 * state.open);
    const endpoint = contact(pin, 2.65);
    const exitX = sleeveEnd + .025;
    const span = endpoint[0] - exitX;
    const middleX = exitX + span * .48;
    // Increase inspection spacing only in the exposed fan, preserving both terminations.
    const spreadY = packedY + (lane * 2.05 - packedY) * state.open;
    const v = (x,y,z=0) => new T.Vector3(x,y,z);
    // A straight bundled section cannot overshoot through the sleeve wall.
    // Only the exposed section bends; both joins have a horizontal tangent.
    const curve = new T.CurvePath();
    curve.add(new T.LineCurve3(v(-4.1,packedY),v(exitX,packedY)));
    curve.add(new T.CubicBezierCurve3(v(exitX,packedY),v(exitX+span*.16,packedY),v(middleX-span*.16,spreadY),v(middleX,spreadY)));
    curve.add(new T.CubicBezierCurve3(v(middleX,spreadY),v(middleX+span*.18,spreadY),v(endpoint[0]-span*.16,endpoint[1],endpoint[2]),new T.Vector3(...endpoint)));
    const conductor = mesh(new T.TubeGeometry(curve,84,radius,8,false),color,part);
    conductor.userData.wirePin = pin;
    conductor.userData.cableRoute = true;
    conductor.userData.sleeveEnd = sleeveEnd;
    if (coax) {
      // Open half-shells expose the centre conductor. The shield remains coaxial.
      const tube = new T.TubeGeometry(curve,42,radius*2.05,12,false);
      if (state.open > .15) {
        const indices=[];
        for(let segment=0;segment<42;segment++) for(let side=0;side<6;side++) {
          const k=segment*13+side;indices.push(k,k+13,k+1,k+13,k+14,k+1);
        }
        tube.setIndex(indices);
      }
      const dielectric=tube.clone();
      // The dielectric separates each copper centre conductor from its shield.
      const innerTube=new T.TubeGeometry(curve,42,radius*1.55,12,false);
      dielectric.setAttribute('position',innerTube.getAttribute('position').clone());
      innerTube.dispose();
      for (const layer of [mesh(dielectric,'#e3eaf0','coax'),mesh(tube,'#96a8b5','coax',.7)]) {
        layer.userData.wirePin = pin;
        layer.userData.cableRoute = true;
        layer.userData.sleeveEnd = sleeveEnd;
      }
      path([endpoint,[2.68,endpoint[1],-.19],[2.76,-.34,-.19]],.012,'#96a8b5','coax');
    }
    path([endpoint,contact(pin,3.08),contact(pin)],radius*.6,color,part).userData.wirePin=pin;
  }
  function rebuild() {
    assembly.traverse(o => { if (o.isMesh) { o.geometry.dispose(); o.material.dispose(); } });
    scene.remove(assembly); assembly = new T.Group(); scene.add(assembly); pickable = [];
    const opening = state.open;
    // Intact rear cable, with the cutaway's jacket and foil retracting towards it.
    const jacketEnd = 2.45 - opening * 4.9;
    const jacketLength = jacketEnd + 4.2;
    cylinder((-4.2 + jacketEnd) / 2, jacketLength, .46, '#3e4d5d', 'jacket');
    const shieldEnd = Math.min(2.5, jacketEnd + .18 + .45 * opening);
    cylinder((-4.12 + shieldEnd) / 2, shieldEnd + 4.12, .425, '#a1aebb', 'shield');
    // Counter-wound strands show the outer braid in the exposed collar.
    for (const direction of [-1,1]) for (let strand=0;strand<10;strand++) {
      const points=[];
      for(let i=0;i<=24;i++) {
        const t=i/24;
        const angle=strand*Math.PI/5 + direction*t*Math.PI*2;
        points.push([jacketEnd+t*(shieldEnd-jacketEnd),Math.cos(angle)*.437,Math.sin(angle)*.437]);
      }
      path(points,.009,'#aebdc7','shield');
    }
    const full = state.cable !== 'basic';
    route('power','#de5860',-1.15,.072,'A4');
    route('ground','#526278',-.9,.072,'A1');
    route('usb2','#2d9a74',-.62,.029,'A6');
    route('usb2','#72bea2',-.49,.029,'A7');
    route('cc','#dba125',-.22,.032,'A5');
    if (full) {
      ['A2','A3','B11','B10','B2','B3','A11','A10'].forEach((pin,i)=>
        route('highspeed',i%2?'#7daee5':'#327dd1',.05+i*.17,.024,pin,true));
      route('sideband','#9965c5',1.53,.026,'A8');
      route('sideband','#c09bde',1.67,.026,'B8');
    }
    // All four power contacts and all four ground contacts are bonded per plug.
    for (const [part,pins,color,y] of [
      ['power',['A4','A9','B4','B9'],'#de5860',-.27],
      ['ground',['A1','A12','B1','B12'],'#526278',-.34]
    ]) {
      path([[2.55,y,-.19],[3.15,y,-.19]],.028,color,part);
      for (const pin of pins) path([[2.76,y,-.19],contact(pin,3.15),contact(pin)],.019,color,part);
    }
    // Outer shield / shell bond joins the same local ground bus.
    path([[shieldEnd,-.4,0],[2.38,-.43,-.2],[2.76,-.34,-.19],[3.42,-.36,0]],.021,'#96a8b5','shield');
    box(2.92,0,-.04,.86,.72,.055,'#17645c',null);
    if (full) {
      // Electrical function blocks: three marker nets, Ra, and the VBUS capacitor.
      box(2.76,.08,.11,.3,.23,.14,'#293440','marker');
      path([contact('B5',3.15),[2.96,.22,.16],[2.82,.17,.16]],.016,'#c179b9','vconn');
      path([[2.7,.17,.16],[2.56,.2,.16],contact('A5',2.65)],.014,'#dba125','cc');
      path([[2.76,-.035,.13],[2.76,-.34,-.19]],.014,'#526278','ground');
      box(3.08,.21,.12,.1,.07,.06,'#ad885b','vconn');
      path([[2.96,.22,.16],[3.03,.21,.12]],.012,'#c179b9','vconn');
      path([[3.13,.21,.12],[3.2,.25,-.19],[2.76,-.34,-.19]],.012,'#526278','ground');
      box(2.92,-.21,.11,.12,.07,.065,'#ad885b','capacitor');
      path([[2.86,-.21,.11],[2.76,-.27,-.19]],.014,'#de5860','capacitor');
      path([[2.98,-.21,.11],[2.76,-.34,-.19]],.014,'#526278','capacitor');
    }
    const housing = box(2.91, opening * 1.02, -.21 - opening*.5, 1.18,.82,.46,'#465566','jacket');
    housing.rotation.x = opening * -.28;
    // Rounded USB-C metal sleeve, open through the front rather than a solid block.
    const shape = new T.Shape();
    const rounded = (s,w,h,r) => { s.moveTo(-w/2+r,-h/2); s.lineTo(w/2-r,-h/2); s.quadraticCurveTo(w/2,-h/2,w/2,-h/2+r); s.lineTo(w/2,h/2-r); s.quadraticCurveTo(w/2,h/2,w/2-r,h/2); s.lineTo(-w/2+r,h/2); s.quadraticCurveTo(-w/2,h/2,-w/2,h/2-r); s.lineTo(-w/2,-h/2+r); s.quadraticCurveTo(-w/2,-h/2,-w/2+r,-h/2); };
    rounded(shape,.34,.79,.15); const hole=new T.Path(); rounded(hole,.23,.67,.105); shape.holes.push(hole);
    const sleeve=mesh(new T.ExtrudeGeometry(shape,{depth:.9,bevelEnabled:false,curveSegments:12}),'#b8c6ce','shield',.85);
    sleeve.rotation.y=Math.PI/2; sleeve.position.set(3.35,0,0);
    // Open plug cavity with contacts on its two inner faces (no receptacle tongue).
    const connected = new Set(data.connections.filter(c=>full || c.basic).flatMap(c=>c.from.split(', ')));
    if (full) connected.add('B5');
    for (const pin of connected) {
      const [x,y,z]=contact(pin,3.85);
      const connection=data.connections.find(c=>c.from.split(', ').includes(pin));
      const pad=box(x,y,z,.6,.031,.014,'#cbb276',connection?.part || 'vconn',.8);
      if(connection)pad.userData.wirePin=pin;
      pad.userData.pin=pin;
    }
    highlight();
  }
  function highlight() {
    const extras = new Set(data.parts.filter(p=>p.extra).map(p=>p.id));
    for (const o of pickable) {
      const selected = state.wire ? (o.userData.wirePin === state.wire || (['power','ground'].includes(state.selected) && o.userData.part===state.selected)) : o.userData.part === state.selected;
      const additional = extras.has(o.userData.part);
      const dimmed = state.differences && !additional;
      o.material.color.copy(o.userData.base);
      if (selected) {
        o.material.color.set('#0066ff');
        o.material.emissive.set('#0066ff');
        o.material.emissiveIntensity = .65;
      } else {
        if(state.differences && additional)o.material.color.set('#cc6500');
        else o.material.color.lerp(new T.Color('#a9b6c2'), dimmed ? .72 : (state.selected ? .32 : 0));
        o.material.emissive.set(state.differences && additional ? '#16385d' : '#000000');
        o.material.emissiveIntensity = state.differences && additional ? .32 : 0;
      }
    }
    render();
  }
  return { rebuild, highlight, closeUp, reset };
}
init();
