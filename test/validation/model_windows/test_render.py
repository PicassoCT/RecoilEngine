# This file is part of the Spring engine (GPL v2 or later), see LICENSE.html
"""Exercise shipped Lua/GLSL on Mesa EGL. Does not substitute for an engine run.
Dependencies: numpy, PyOpenGL, lupa, Mesa EGL (compatibility OpenGL).
Run from repo root: python test/validation/model_windows/test_render.py
"""
import os
os.environ.setdefault("PYOPENGL_PLATFORM", "egl")
os.environ.setdefault("EGL_PLATFORM", "surfaceless")
from ctypes import byref, c_int
from pathlib import Path
import numpy as np
from OpenGL import EGL, GL as G
from OpenGL.GL import shaders
from lupa.lua51 import LuaRuntime

ROOT = Path(__file__).resolve().parents[3] / "cont/base/springcontent"
WIDTH, HEIGHT = 128, 96

def context():
	display = EGL.eglGetDisplay(EGL.EGL_DEFAULT_DISPLAY)
	major, minor = c_int(), c_int()
	assert EGL.eglInitialize(display, byref(major), byref(minor))
	EGL.eglBindAPI(EGL.EGL_OPENGL_API)
	attrs = (c_int * 11)(EGL.EGL_SURFACE_TYPE, EGL.EGL_PBUFFER_BIT,
		EGL.EGL_RENDERABLE_TYPE, EGL.EGL_OPENGL_BIT, EGL.EGL_RED_SIZE, 8,
		EGL.EGL_DEPTH_SIZE, 24, EGL.EGL_STENCIL_SIZE, 8, EGL.EGL_NONE)
	configs, count = (EGL.EGLConfig * 1)(), c_int()
	assert EGL.eglChooseConfig(display, attrs, configs, 1, byref(count)) and count.value
	surface = EGL.eglCreatePbufferSurface(display, configs[0],
		(c_int * 5)(EGL.EGL_WIDTH, WIDTH, EGL.EGL_HEIGHT, HEIGHT, EGL.EGL_NONE))
	ctx = EGL.eglCreateContext(display, configs[0], EGL.EGL_NO_CONTEXT, None)
	assert EGL.eglMakeCurrent(display, surface, surface, ctx)
	return display, surface, ctx

DISPLAY, PBUFFER, CONTEXT = context()
print("OpenGL:", G.glGetString(G.GL_RENDERER).decode())
lua = LuaRuntime(unpack_returned_tuples=True)

def table(**kwargs): return lua.table_from(kwargs)
def sequence(value): return [value[i] for i in range(1, len(value)+1)]
def toggle(cap, enabled): (G.glEnable if enabled else G.glDisable)(cap)
def depth_test(value):
	toggle(G.GL_DEPTH_TEST, value is not False)
	if value is not False: G.glDepthFunc(int(value))
def polygon_offset(*args):
	toggle(G.GL_POLYGON_OFFSET_FILL, args[0] is not False)
	if args[0] is not False: G.glPolygonOffset(*args)
def clip_plane(index, *args):
	plane = G.GL_CLIP_PLANE4 + index - 1
	if args[0] is False: G.glDisable(plane)
	else: G.glClipPlane(plane, args); G.glEnable(plane)
def begin_end(mode, fn):
	G.glBegin(mode)
	try: fn()
	finally: G.glEnd()
def create_list(fn):
	result = G.glGenLists(1)
	G.glNewList(result, G.GL_COMPILE)
	try: fn()
	finally: G.glEndList()
	return result
def active_shader(program, fn):
	previous = int(G.glGetIntegerv(G.GL_CURRENT_PROGRAM))
	G.glUseProgram(program)
	try: fn()
	finally: G.glUseProgram(previous)
def push_pop_matrix(*args):
	if isinstance(args[0], (int, float)):
		G.glMatrixMode(int(args[0])); args = args[1:]
	G.glPushMatrix()
	try: args[0](*args[1:])
	finally: G.glPopMatrix()
def create_shader(definition):
	program = shaders.compileProgram(
		shaders.compileShader(definition['vertex'], G.GL_VERTEX_SHADER),
		shaders.compileShader(definition['fragment'], G.GL_FRAGMENT_SHADER))
	def init():
		for name, value in definition['uniformInt'].items():
			G.glUniform1i(G.glGetUniformLocation(program, name), value)
	active_shader(program, init)
	return program
def uniform(location, *values):
	getattr(G, 'glUniform%df' % len(values))(location, *values)
def get_number(enum, count=1):
	values = np.asarray(G.glGetFloatv(enum)).reshape(-1)
	return tuple(float(x) for x in values[:count]) if count > 1 else float(values[0])
def quad(left, bottom, right, top, z=0):
	G.glBegin(G.GL_QUADS)
	G.glNormal3f(0, 0, 1)
	for x,y in [(left,bottom),(right,bottom),(right,top),(left,top)]:
		G.glTexCoord2f(0.5,0.5); G.glVertex3f(x,y,z)
	G.glEnd()

def texture(rgba):
	tex = G.glGenTextures(1)
	G.glBindTexture(G.GL_TEXTURE_2D, tex)
	G.glTexParameteri(G.GL_TEXTURE_2D, G.GL_TEXTURE_MIN_FILTER, G.GL_NEAREST)
	G.glTexParameteri(G.GL_TEXTURE_2D, G.GL_TEXTURE_MAG_FILTER, G.GL_NEAREST)
	G.glTexImage2D(G.GL_TEXTURE_2D, 0, G.GL_RGBA8, 1,1,0, G.GL_RGBA,
		G.GL_UNSIGNED_BYTE, bytes(rgba))
	return tex

# Synthetic model loader: tests the real Lua renderer and shaders with known
# geometry/textures, not the native model loader, its formats or callin routing.
TEXTURES = {'objects3d/blue.s3o':texture((0,0,255,0)),
	'objects3d/yellow.s3o':texture((255,255,0,0)),
	'objects3d/magenta.s3o':texture((255,0,255,0))}
EXTRA = texture((0,0,0,255))
model_draws = []
fail_model = False

def model_textures(path, push):
	if push:
		for unit, tex in [(0,TEXTURES[path]),(1,EXTRA)]:
			G.glActiveTexture(G.GL_TEXTURE0+unit); G.glBindTexture(G.GL_TEXTURE_2D, tex)
		G.glActiveTexture(G.GL_TEXTURE0)
def model_shape(path):
	model_draws.append(path)
	if fail_model: raise RuntimeError('injected model failure')
	quad(-1,-1,1,1)

api = dict(CreateShader=create_shader, DeleteShader=G.glDeleteProgram,
	GetShaderLog=lambda:'', GetUniformLocation=G.glGetUniformLocation,
	GetNumber=get_number, GetMatrixData=lambda mode:tuple(float(v) for v in np.asarray(
		G.glGetFloatv(G.GL_MODELVIEW_MATRIX if mode == G.GL_MODELVIEW else G.GL_PROJECTION_MATRIX)).reshape(-1)),
	Translate=G.glTranslatef, Rotate=G.glRotatef, Scale=G.glScalef,
	ModelShape=model_shape, ModelShapeTextures=model_textures, PushPopMatrix=push_pop_matrix,
	Uniform=uniform, UniformInt=G.glUniform1i, ActiveShader=active_shader,
	CreateList=create_list, DeleteList=lambda id:G.glDeleteLists(id,1),
	CallList=G.glCallList, BeginEnd=begin_end, Vertex=G.glVertex3f,
	PushAttrib=G.glPushAttrib, PopAttrib=G.glPopAttrib, MatrixMode=G.glMatrixMode,
	MultMatrix=lambda m:G.glMultMatrixf(sequence(m)),
	Blending=lambda enabled:toggle(G.GL_BLEND,enabled),
	AlphaTest=lambda enabled:toggle(G.GL_ALPHA_TEST,enabled),
	Culling=lambda enabled:toggle(G.GL_CULL_FACE,enabled), ClipPlane=clip_plane,
	StencilTest=lambda enabled:toggle(G.GL_STENCIL_TEST,enabled),
	StencilMask=G.glStencilMask, StencilFunc=G.glStencilFunc, StencilOp=G.glStencilOp,
	ColorMask=G.glColorMask, DepthMask=G.glDepthMask, DepthTest=depth_test,
	PolygonOffset=polygon_offset)
lua.globals().gl = table(**api)
lua.globals().GL = lua.table_from({key[3:]:int(getattr(G,key)) for key in dir(G)
	if key.startswith('GL_') and isinstance(getattr(G,key),int)})
lua.globals().VFS = table(Include=lambda path:lua.execute((ROOT/path).read_text()),
	LoadFile=lambda path:(ROOT/path).read_text(), FileExists=lambda path:path in TEXTURES)
lua.globals().Spring = table(PreloadModel=lambda path:None)
lua.execute('''
Windows = VFS.Include("LuaModelWindows/ModelWindows.lua")
w = Windows.New({minPixels=0})
scene = w:CreateScene({ambient=1})
blue = w:AddModel(scene,"blue.s3o",{position={0,0,-1},scale={4,3,1}})
front = w:AddModel(scene,"magenta.s3o",{position={0,0,1},scale={4,3,1}})
surface = w:CreateSurface({polygons={
	{{-2,-1},{-0.25,-1},{-0.25,1},{-2,1}},
	{{0.25,-1},{2,-1},{2,1},{0.25,1}},
}})
''')

def reset():
	G.glViewport(0,0,WIDTH,HEIGHT)
	G.glUseProgram(0)
	for cap in [G.GL_STENCIL_TEST,G.GL_BLEND,G.GL_CULL_FACE,G.GL_ALPHA_TEST,
		G.GL_POLYGON_OFFSET_FILL,G.GL_CLIP_PLANE4,G.GL_CLIP_PLANE5]: G.glDisable(cap)
	G.glDepthMask(True); G.glColorMask(True,True,True,True); G.glStencilMask(255)
	G.glClearColor(0,0,0,1); G.glClearDepth(1); G.glClearStencil(5)
	G.glClear(G.GL_COLOR_BUFFER_BIT|G.GL_DEPTH_BUFFER_BIT|G.GL_STENCIL_BUFFER_BIT)
	G.glEnable(G.GL_DEPTH_TEST); G.glDepthFunc(G.GL_LEQUAL)
	G.glMatrixMode(G.GL_PROJECTION); G.glLoadIdentity(); G.glOrtho(-4,4,-3,3,1,20)
	G.glMatrixMode(G.GL_MODELVIEW); G.glLoadIdentity(); G.glTranslatef(0,0,-6)
	G.glColor3f(1,0,0); quad(-4,-3,4,3) # opaque hull
	G.glColor3f(0,1,0); quad(1,-0.5,1.5,0.5,1) # foreground obstacle
	model_draws.clear()

def pixels(kind=G.GL_RGBA, dtype=G.GL_UNSIGNED_BYTE):
	return np.asarray(G.glReadPixels(0,0,WIDTH,HEIGHT,kind,dtype)) if dtype == G.GL_FLOAT else np.frombuffer(
		G.glReadPixels(0,0,WIDTH,HEIGHT,kind,dtype),dtype=np.uint8).reshape(HEIGHT,WIDTH,-1)
def at(img,x,y): return img[int((y+3)/6*HEIGHT),int((x+4)/8*WIDTH)]
def color(img,x,y,expected):
	actual=at(img,x,y)[:3]
	assert np.max(np.abs(actual.astype(int)-expected)) < 3, (x,y,actual,expected)
def assert_buffers(depth):
	current = pixels(G.GL_DEPTH_COMPONENT,G.GL_FLOAT)
	assert np.max(np.abs(current-depth)) < 1e-6, 'exterior depth changed'
	assert np.all(pixels(G.GL_STENCIL_INDEX) == 5), 'foreign stencil bits changed or scratch leaked'

reset()
depth = pixels(G.GL_DEPTH_COMPONENT,G.GL_FLOAT).copy()
assert lua.eval('w:DrawSurface(surface,scene)')
img = pixels()
color(img,-1,0,[0,0,255]); color(img,0,0,[255,0,0]); color(img,3,0,[255,0,0])
color(img,1.25,0,[0,255,0]); color(img,0.5,0,[0,0,255])
assert len(model_draws) == 2, 'each scene model must draw once for the entire aperture group'
assert_buffers(depth)
# Magenta in front of the plane is clipped; real scene updates are reused.
lua.execute('yellow=w:AddModel(scene,"yellow.s3o",{position={-1,0,-0.5},scale=0.4})')
reset(); lua.execute('w:DrawSurface(surface,scene)')
color(pixels(),-1,0,[255,255,0])
lua.execute('w:UpdateModel(scene,yellow,{position={0.5,0,-0.5},scale=0.2})')
reset(); lua.execute('w:DrawSurface(surface,scene)')
color(pixels(),-1,0,[0,0,255]); color(pixels(),0.5,0,[255,255,0])
lua.execute('w:RemoveModel(scene,yellow)')

# Perspective views and Recoil's zero-to-one clip-space mode. A rear prop's
# image shifts relative to the hull as the eye moves (true geometric parallax).
lua.execute('wide=w:CreateSurface({width=4,height=2}); rear=w:AddModel(scene,"yellow.s3o",{position={0,0,-2},scale=0.2})')
# Put the blue room wall behind the prop.
lua.execute('w:UpdateModel(scene,blue,{position={0,0,-3}})')
for zero_to_one in [False, True]:
	G.glClipControl(G.GL_LOWER_LEFT, G.GL_ZERO_TO_ONE if zero_to_one else G.GL_NEGATIVE_ONE_TO_ONE)
	for camera_x in [-1,1]:
		reset()
		G.glClear(G.GL_COLOR_BUFFER_BIT|G.GL_DEPTH_BUFFER_BIT|G.GL_STENCIL_BUFFER_BIT)
		G.glMatrixMode(G.GL_PROJECTION); G.glLoadIdentity()
		G.glFrustum(-2/3,2/3,-0.5,0.5,1,20)
		if zero_to_one:
			projection = np.asarray(G.glGetFloatv(G.GL_PROJECTION_MATRIX)).copy()
			projection[:,2] = (projection[:,2] + projection[:,3])*0.5
			G.glLoadMatrixf(projection)
		G.glMatrixMode(G.GL_MODELVIEW); G.glLoadIdentity(); G.glTranslatef(-camera_x,0,-6)
		G.glColor3f(1,0,0); quad(-4,-3,4,3)
		before_depth = pixels(G.GL_DEPTH_COMPONENT,G.GL_FLOAT).copy()
		assert lua.eval('w:DrawSurface(wide,scene)')
		image = pixels()
		pixel_x = int((1-camera_x/8/(2/3))*WIDTH/2)
		assert np.array_equal(image[HEIGHT//2,pixel_x,:3],[255,255,0]), 'perspective prop projection'
		assert_buffers(before_depth)
G.glClipControl(G.GL_LOWER_LEFT, G.GL_NEGATIVE_ONE_TO_ONE)
lua.execute('w:RemoveModel(scene,rear); w:UpdateModel(scene,blue,{position={0,0,-1}})')

# State/error cleanup includes shader, matrix, color/depth mask, stencil bits.
reset()
G.glEnable(G.GL_BLEND); G.glBlendFunc(G.GL_SRC_ALPHA,G.GL_ONE_MINUS_SRC_ALPHA)
G.glDepthMask(False)
previous = {key:np.asarray(G.glGetFloatv(key)).copy() for key in
	[G.GL_DEPTH_WRITEMASK,G.GL_COLOR_WRITEMASK,G.GL_MODELVIEW_MATRIX,G.GL_STENCIL_WRITEMASK,G.GL_CURRENT_PROGRAM]}
fail_model = True
try: lua.execute('w:DrawSurface(surface,scene)')
except Exception as exc: assert 'injected model failure' in str(exc)
else: raise AssertionError('draw failure was swallowed')
fail_model = False
assert lua.eval('not w.drawing')
for key, value in previous.items(): assert np.array_equal(G.glGetFloatv(key),value), key
assert G.glIsEnabled(G.GL_BLEND)
assert_buffers(depth)
G.glDepthMask(True)
lua.execute('w:DrawSurface(surface,scene)')
# The later transparent pass overlays the window and keeps foreground geometry.
G.glColor4f(1,1,0,0.5); quad(-2,-1,-0.25,1,0.5)
color(pixels(),-1,0,[128,128,127])

# Back-facing, offscreen and distant surfaces consume no model draws.
reset(); G.glRotatef(180,0,1,0)
assert not lua.eval('w:DrawSurface(surface,scene)') and not model_draws
reset(); G.glTranslatef(100,0,0)
assert not lua.eval('w:DrawSurface(surface,scene)') and not model_draws
reset(); G.glTranslatef(0,0,-3000)
assert not lua.eval('w:DrawSurface(surface,scene)') and not model_draws
reset(); G.glEnable(G.GL_STENCIL_TEST)
try: lua.execute('w:DrawSurface(surface,scene)')
except Exception as exc: assert 'active stencil pass' in str(exc)
else: raise AssertionError('nested stencil pass accepted')
G.glDisable(G.GL_STENCIL_TEST)
lua.execute('w:Shutdown()')
assert G.glGetError() == G.GL_NO_ERROR
print('ModelWindows real GL: clipping, shared group, foreground, dynamic models, depth/stencil restoration, error cleanup, transparency, perspective parallax, zero-to-one depth and culling passed')
EGL.eglMakeCurrent(DISPLAY,EGL.EGL_NO_SURFACE,EGL.EGL_NO_SURFACE,EGL.EGL_NO_CONTEXT)
EGL.eglDestroyContext(DISPLAY,CONTEXT); EGL.eglDestroySurface(DISPLAY,PBUFFER); EGL.eglTerminate(DISPLAY)
