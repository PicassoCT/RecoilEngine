/* This file is part of the Spring engine (GPL v2 or later), see LICENSE.html */
#version 120
varying vec2 texCoord;
varying vec3 normal;
void main() {
	vec4 eyeVertex = gl_ModelViewMatrix * gl_Vertex;
	gl_Position = gl_ProjectionMatrix * eyeVertex;
	gl_ClipVertex = eyeVertex;
	texCoord = gl_MultiTexCoord0.st;
	normal = gl_NormalMatrix * gl_Normal;
}
