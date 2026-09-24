(() => {
  const canvas = document.querySelector('#scene');
  const status = document.querySelector('#status');
  const fixture = window.wallbloomFixture = {
    loaded: true, frames: 0, pointer: [0, 0], pauseCalls: 0, resumeCalls: 0, timerTicks: 0,
  };
  let paused = false;
  const timer = setInterval(() => { if (!paused) fixture.timerTicks++; }, 10);
  window.wallbloom.pause = () => { if (!paused) fixture.pauseCalls++; paused = true; };
  window.wallbloom.resume = () => { if (paused) fixture.resumeCalls++; paused = false; };
  canvas.addEventListener('pointermove', e => { fixture.pointer = [e.clientX, e.clientY]; });

  // The normal fixture is deliberately lightweight. Add ?heavy=1 for the WebGL stress scene.
  const heavy = new URLSearchParams(document.currentScript.src.split('?')[1] || location.search).has('heavy');
  const scale = 0.5;
  function resize() {
    canvas.width = Math.max(1, Math.round(innerWidth * scale));
    canvas.height = Math.max(1, Math.round(innerHeight * scale));
    if (gl) gl.viewport(0, 0, canvas.width, canvas.height);
  }

  let gl = canvas.getContext('webgl');
  if (!gl) { status.textContent = 'WEBGL UNAVAILABLE'; return; }
  const shader = (type, source) => {
    const result = gl.createShader(type);
    gl.shaderSource(result, source);
    gl.compileShader(result);
    if (!gl.getShaderParameter(result, gl.COMPILE_STATUS)) throw Error(gl.getShaderInfoLog(result));
    return result;
  };
  if (heavy) {
    const program = gl.createProgram();
    gl.attachShader(program, shader(gl.VERTEX_SHADER, 'attribute vec2 p; void main(){gl_Position=vec4(p,0.,1.);}'));
    gl.attachShader(program, shader(gl.FRAGMENT_SHADER,
      'precision mediump float; uniform vec2 r; uniform vec2 m; uniform float t; void main(){vec2 u=gl_FragCoord.xy/r; vec2 delta=u-m/r; float d=dot(delta,delta); gl_FragColor=vec4(0.12+0.5*abs(sin(t+sqrt(d)*8.)),0.16+0.4*u.x,0.35+0.5*u.y,1.);}'));
    gl.linkProgram(program);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) throw Error(gl.getProgramInfoLog(program));
    gl.useProgram(program);
    const buffer = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1,-1, 1,-1, -1,1, 1,1]), gl.STATIC_DRAW);
    const position = gl.getAttribLocation(program, 'p');
    gl.enableVertexAttribArray(position);
    gl.vertexAttribPointer(position, 2, gl.FLOAT, false, 0, 0);
    const resolution = gl.getUniformLocation(program, 'r');
    const pointer = gl.getUniformLocation(program, 'm');
    const time = gl.getUniformLocation(program, 't');
    const start = performance.now();
    window.addEventListener('resize', resize);
    resize();
    run((now) => {
      gl.uniform2f(resolution, canvas.width, canvas.height);
      gl.uniform2f(pointer, fixture.pointer[0] * scale, fixture.pointer[1] * scale);
      gl.uniform1f(time, (now - start) / 1000);
      gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
    }, 'WEBGL OK heavy');
  } else {
    const program = gl.createProgram();
    gl.attachShader(program, shader(gl.VERTEX_SHADER, 'attribute vec2 p; void main(){gl_Position=vec4(p,0.,1.);}'));
    gl.attachShader(program, shader(gl.FRAGMENT_SHADER,
      'precision mediump float; uniform float t; void main(){vec2 u=gl_FragCoord.xy/vec2(1280.,720.); float glow=0.; for(int i=0;i<8;i++){vec2 p=vec2(fract(float(i)*0.618),fract(float(i)*0.371+t*0.025)); vec2 d=u-p; glow+=max(0.,0.012-dot(d,d))*8.;} gl_FragColor=vec4(mix(vec3(0.09,0.16,0.3),vec3(0.32,0.28,0.48),u.y)+glow,1.);}'));
    gl.linkProgram(program);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) throw Error(gl.getProgramInfoLog(program));
    gl.useProgram(program);
    const buffer = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1,-1, 1,-1, -1,1, 1,1]), gl.STATIC_DRAW);
    const position = gl.getAttribLocation(program, 'p');
    gl.enableVertexAttribArray(position);
    gl.vertexAttribPointer(position, 2, gl.FLOAT, false, 0, 0);
    const time = gl.getUniformLocation(program, 't');
    const start = performance.now();
    window.addEventListener('resize', resize);
    resize();
    run((now) => { gl.uniform1f(time, (now - start) / 1000); gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4); }, 'WEBGL OK light');
  }

  function run(draw, label) {
    const frameInterval = 1000 / 30;
    let lastFrame = 0;
    function frame(now) {
      requestAnimationFrame(frame);
      if (paused || now - lastFrame < frameInterval) return;
      lastFrame = now;
      draw(now);
      fixture.frames++;
      status.textContent = `${label} frames=${fixture.frames}`;
    }
    requestAnimationFrame(frame);
  }
})();
